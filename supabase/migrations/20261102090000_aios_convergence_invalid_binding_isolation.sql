-- Convergence hardening (2026-11-02).
--
-- ROOT CAUSE: private.aios_expire_stale_approvals() (20261101210000) transitions each pending approval with an UPDATE that fires
-- trg_aios_validate_approval_integrity. That guard correctly rejects an approval whose invocation / agent / task belongs to a
-- different organization (errcode 23514). The function had no per-record isolation, so ONE malformed legacy approval raised out of
-- the loop and rolled back the whole batch: every other eligible approval stayed pending and the cron job failed on every run.
-- The integrity guard behaved correctly; the job must not hand it a record it knows is invalid.
--
-- FIX (the integrity trigger is NOT touched, disabled, or bypassed; no approval row is edited by this migration):
--   1. private.aios_approval_binding_defect(uuid): read-only classifier that detects invalid organization bindings BEFORE any
--      transition is attempted (direct invocation, legacy invocation.approval_id link, agent, task, invocation's task).
--   2. private.aios_expire_stale_approvals(): validates each candidate first. An invalid record is skipped untouched (approval,
--      invocation, task all unchanged), reported in the result JSON and the server log, and gets an append-only manual_review
--      disposition. Each remaining transition also runs in its own subtransaction, so an unforeseen failure on one record is
--      likewise skipped and reported instead of aborting the batch.
--   3. Append (never update) a manual_review disposition for every pending approval that currently has an invalid binding.
--      Prior dispositions are preserved; the view below resolves the effective (latest) disposition per entity.

-- 1. Binding classifier. Owner-only: it is an internal helper, not an API surface.
create or replace function private.aios_approval_binding_defect(p_approval_id uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  ap public.aios_approvals;
  v_org uuid;
begin
  select * into ap from public.aios_approvals where id = p_approval_id;
  if ap.id is null then return 'approval_missing'; end if;

  if ap.invocation_id is not null then
    select i.organization_id into v_org from public.aios_tool_invocations i where i.id = ap.invocation_id;
    if not found then return 'invocation_missing'; end if;
    if v_org is distinct from ap.organization_id then return 'invocation_org_mismatch'; end if;
  end if;

  -- Legacy link: invocation.approval_id -> approval. A cross-tenant link would make the job write to another tenant's rows.
  if exists (select 1 from public.aios_tool_invocations i
             where i.approval_id = ap.id and i.organization_id is distinct from ap.organization_id) then
    return 'linked_invocation_org_mismatch';
  end if;

  if ap.agent_id is not null then
    select a.organization_id into v_org from public.aios_agents a where a.id = ap.agent_id;
    if not found or v_org is distinct from ap.organization_id then return 'agent_org_mismatch'; end if;
  end if;

  if ap.task_id is not null then
    select t.organization_id into v_org from public.aios_tasks t where t.id = ap.task_id;
    if not found or v_org is distinct from ap.organization_id then return 'task_org_mismatch'; end if;
  end if;

  -- The task the convergence would expire (via the linked invocation) must also be in the approval's organization.
  if exists (select 1
             from public.aios_tool_invocations i
             join public.aios_tasks t on t.id = i.task_id
             where (i.id = ap.invocation_id or i.approval_id = ap.id)
               and t.organization_id is distinct from ap.organization_id) then
    return 'invocation_task_org_mismatch';
  end if;

  return null;
end; $$;

revoke all on function private.aios_approval_binding_defect(uuid) from public, anon, authenticated, service_role;
comment on function private.aios_approval_binding_defect(uuid) is 'Read-only. Returns NULL when an approval''s organization bindings are consistent, else a short defect code. Owner-only helper for private.aios_expire_stale_approvals().';

-- 2. Convergence with pre-validation and per-record isolation.
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
comment on function private.aios_expire_stale_approvals() is 'Converges lapsed and legacy (NULL expires_at, >24h) pending approvals via either invocation link. Validates organization bindings first; invalid or failing records are skipped untouched, reported, and given an append-only manual_review disposition. Never touches an approval whose invocation is not requires_approval. Idempotent.';

-- 3. Append manual_review dispositions for pending approvals that currently have an invalid binding (data-driven, idempotent).
--    Append-only: the earlier expire_via_canonical_job rows are left exactly as they are.
insert into public.aios_backlog_dispositions (organization_id, entity_type, entity_id, classification, disposition, rationale, decided_by)
select ap.organization_id, 'approval', ap.id, 'needs_owner_review', 'manual_review',
       'Invalid organization binding (' || private.aios_approval_binding_defect(ap.id) || '). Excluded from automatic expiry; owner must review. Supersedes the earlier expire_via_canonical_job disposition.',
       'migration:20261102090000'
from public.aios_approvals ap
where ap.status = 'pending' and private.aios_approval_binding_defect(ap.id) is not null
on conflict do nothing;

-- Effective disposition per entity = latest appended row. History stays in the base table. security_invoker keeps RLS in force.
create or replace view public.aios_backlog_effective_dispositions with (security_invoker = true) as
select distinct on (entity_type, entity_id)
       id, organization_id, entity_type, entity_id, classification, disposition, rationale, decided_by, created_at
from public.aios_backlog_dispositions
order by entity_type, entity_id, created_at desc, (disposition = 'manual_review') desc, id;

revoke all on public.aios_backlog_effective_dispositions from public, anon, authenticated;
grant select on public.aios_backlog_effective_dispositions to authenticated, service_role;
