-- Phase 2/3 closure (mandate 2026-11-01).
--
-- ROOT CAUSE: private.aios_expire_stale_approvals() joined approvals to invocations on aios_approvals.invocation_id and
-- required expires_at IS NOT NULL. All 21 legacy pending approvals have invocation_id NULL and expires_at NULL (15 are linked
-- only through aios_tool_invocations.approval_id; 6 have no invocation), so the job could never converge them.
--
-- FIX: (1) resolve the invocation through either link, (2) treat a pending approval with NULL expires_at older than the legacy
-- cutoff as lapsed, (3) never touch an approval whose linked invocation is in any state other than requires_approval,
-- (4) use only the existing canonical pending -> expired transition (no expires_at rewrite, no deletes).
-- Dispositions for legacy approvals and the queued backlog are recorded in an append-only table. No task is revived,
-- deleted or edited by this migration.

create table if not exists public.aios_backlog_dispositions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  entity_type text not null check (entity_type in ('approval','task','mission')),
  entity_id uuid not null,
  classification text not null check (classification in (
    'orphaned_approval','untethered_fixture_approval','historical_test_fixture','legitimate_pending_work','needs_owner_review')),
  disposition text not null check (disposition in ('expire_via_canonical_job','retain_queued_no_action','manual_review')),
  rationale text not null,
  decided_by text not null default 'migration:20261101210000',
  created_at timestamptz not null default now(),
  unique (entity_type, entity_id, classification)
);
create index if not exists idx_aios_backlog_dispositions_org on public.aios_backlog_dispositions (organization_id, entity_type);

alter table public.aios_backlog_dispositions enable row level security;
revoke all on public.aios_backlog_dispositions from public, anon, authenticated;
grant select on public.aios_backlog_dispositions to authenticated;
grant all on public.aios_backlog_dispositions to service_role;
drop policy if exists aios_backlog_dispositions_member_read on public.aios_backlog_dispositions;
create policy aios_backlog_dispositions_member_read on public.aios_backlog_dispositions
  for select to authenticated using (public.aios_is_org_member(organization_id));

-- Append-only: no UPDATE/DELETE for any role except via migration owner.
create or replace function private.aios_backlog_dispositions_immutable()
returns trigger language plpgsql security definer set search_path = '' as $$
begin raise exception 'aios_backlog_dispositions is append-only' using errcode = '42501'; end; $$;
revoke all on function private.aios_backlog_dispositions_immutable() from public, anon, authenticated;
drop trigger if exists trg_aios_backlog_dispositions_immutable on public.aios_backlog_dispositions;
create trigger trg_aios_backlog_dispositions_immutable
  before update or delete on public.aios_backlog_dispositions
  for each row execute function private.aios_backlog_dispositions_immutable();

-- Record dispositions from current state (idempotent via the unique key).
insert into public.aios_backlog_dispositions (organization_id, entity_type, entity_id, classification, disposition, rationale)
select ap.organization_id, 'approval', ap.id,
       case when i.id is null then 'orphaned_approval' else 'untethered_fixture_approval' end,
       'expire_via_canonical_job',
       case when i.id is null
            then 'Legacy pending approval with NULL expires_at and no linked invocation or task; cannot authorize anything.'
            else 'Legacy pending approval linked only via invocation.approval_id to a requires_approval invocation with no task; pre-dates expiry mechanism.' end
from public.aios_approvals ap
left join public.aios_tool_invocations i on i.approval_id = ap.id
where ap.status = 'pending' and ap.expires_at is null and ap.created_at < now() - interval '24 hours'
on conflict do nothing;

insert into public.aios_backlog_dispositions (organization_id, entity_type, entity_id, classification, disposition, rationale)
select t.organization_id, 'task', t.id,
       case when t.title ~* '(gate|live-gate|test|verify execute-task|attempt customer data export|engineering)' then 'historical_test_fixture' else 'needs_owner_review' end,
       case when t.title ~* '(gate|live-gate|test|verify execute-task|attempt customer data export|engineering)' then 'retain_queued_no_action' else 'manual_review' end,
       case when t.title ~* '(gate|live-gate|test|verify execute-task|attempt customer data export|engineering)'
            then 'Queued task matches a test/gate fixture pattern. Left queued deliberately: gate workflows consume queued tasks as inputs. Not revived, not deleted.'
            else 'Queued task not matching a known fixture pattern; owner must confirm it is legitimate pending work.' end
from public.aios_tasks t where t.status = 'queued'
on conflict do nothing;

insert into public.aios_backlog_dispositions (organization_id, entity_type, entity_id, classification, disposition, rationale)
select m.organization_id, 'mission', m.id,
       case when exists (select 1 from public.aios_tasks s where s.mission_id = m.id and s.title ~* '(gate|live-gate|test|verify execute-task|attempt customer data export|engineering)')
            then 'historical_test_fixture' else 'needs_owner_review' end,
       case when exists (select 1 from public.aios_tasks s where s.mission_id = m.id and s.title ~* '(gate|live-gate|test|verify execute-task|attempt customer data export|engineering)')
            then 'retain_queued_no_action' else 'manual_review' end,
       'Queued mission state mirrors its queued constituent tasks; disposition follows task classification.'
from public.aios_missions m where m.status = 'queued'
on conflict do nothing;

-- Corrected canonical expiry. Same transitions as 20261014174104, plus legacy/unlinked coverage.
create or replace function private.aios_expire_stale_approvals()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a record;
  v_inv uuid; v_inv_status text;
  v_task uuid; v_mission uuid;
  v_expired int := 0; v_tasks_expired int := 0; v_orphans int := 0; v_skipped int := 0;
begin
  for a in
    select ap.id, ap.invocation_id
    from public.aios_approvals ap
    where ap.status = 'pending'
      and ((ap.expires_at is not null and ap.expires_at <= now())
        or (ap.expires_at is null and ap.created_at < now() - interval '24 hours'))
    order by ap.created_at
    for update of ap skip locked
  loop
    v_inv := a.invocation_id; v_inv_status := null;
    if v_inv is null then
      select i.id into v_inv from public.aios_tool_invocations i where i.approval_id = a.id order by i.created_at desc limit 1;
    end if;
    if v_inv is not null then
      select i.status into v_inv_status from public.aios_tool_invocations i where i.id = v_inv for update;
    end if;

    -- A linked invocation in any state other than requires_approval may be in flight: never expire its approval here.
    if v_inv is not null and v_inv_status is distinct from 'requires_approval' then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    update public.aios_approvals
      set status = 'expired', reviewed_at = now(),
          approval_reason = coalesce(approval_reason, 'approval expired before a decision was made')
      where id = a.id and status = 'pending';

    if v_inv is null then
      v_orphans := v_orphans + 1;
      continue;
    end if;

    v_task := null;
    update public.aios_tool_invocations
      set status = 'expired', completed_at = now(), error_code = 'APPROVAL_EXPIRED',
          error_message = 'approval expired before a decision was made'
      where id = v_inv and status = 'requires_approval'
      returning task_id into v_task;
    v_expired := v_expired + 1;

    if v_task is not null then
      v_mission := null;
      update public.aios_tasks
        set status = 'expired', failed_stage = 'approval_expired',
            last_error = 'approval expired before a decision was made',
            result = coalesce(result, '{}'::jsonb) || jsonb_build_object('error', 'approval_expired', 'invocation_id', v_inv)
        where id = v_task and status in ('blocked_pending_approval', 'running')
        returning mission_id into v_mission;
      if v_mission is not null then
        v_tasks_expired := v_tasks_expired + 1;
        update public.aios_missions m set status = 'failed', completed_at = now()
          where m.id = v_mission and m.status in ('running', 'blocked_pending_approval')
            and not exists (
              select 1 from public.aios_tasks s
              where s.mission_id = m.id
                and s.status in ('queued','assigned','ready','running','approved','blocked_pending_approval'));
      end if;
    end if;
  end loop;
  return jsonb_build_object('approvals_expired', v_expired, 'orphan_approvals_expired', v_orphans,
                            'tasks_expired', v_tasks_expired, 'skipped_in_flight', v_skipped);
end; $$;

revoke all on function private.aios_expire_stale_approvals() from public, anon, authenticated;
grant execute on function private.aios_expire_stale_approvals() to service_role;
comment on function private.aios_expire_stale_approvals() is 'Converges lapsed and legacy (NULL expires_at, >24h) pending approvals via either invocation link. Never touches an approval whose invocation is not requires_approval. Idempotent.';
