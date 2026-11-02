-- CAPTURED from production (supabase_migrations.schema_migrations version 20261101232313). Applied outside the repo; recorded here
-- so the repo replays to the live catalog. Transcribed from the recorded statements.
create or replace function private.aios_approval_binding_defect(p_approval_id uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  ap public.aios_approvals;
  v_org uuid;
  inv public.aios_tool_invocations;
begin
  select * into ap from public.aios_approvals where id = p_approval_id;
  if ap.id is null then return 'approval_not_found'; end if;

  if ap.agent_id is not null then
    select a.organization_id into v_org from public.aios_agents a where a.id = ap.agent_id;
    if not found then return 'agent_missing'; end if;
    if v_org <> ap.organization_id then return 'agent_organization_mismatch'; end if;
  end if;

  if ap.task_id is not null then
    select t.organization_id into v_org from public.aios_tasks t where t.id = ap.task_id;
    if not found then return 'task_missing'; end if;
    if v_org <> ap.organization_id then return 'task_organization_mismatch'; end if;
  end if;

  if ap.invocation_id is not null then
    select * into inv from public.aios_tool_invocations i where i.id = ap.invocation_id;
    if inv.id is null then return 'invocation_missing'; end if;
    if inv.organization_id <> ap.organization_id then return 'invocation_organization_mismatch'; end if;
    if ap.agent_id is not null and inv.agent_id is distinct from ap.agent_id then return 'invocation_agent_mismatch'; end if;
    if ap.task_id is not null and inv.task_id is distinct from ap.task_id then return 'invocation_task_mismatch'; end if;
    if ap.tool_key is not null and ap.tool_key is distinct from inv.tool_key then return 'invocation_tool_mismatch'; end if;
    if ap.arguments_hash is not null and ap.arguments_hash is distinct from inv.arguments_hash then return 'invocation_arguments_mismatch'; end if;
    if ap.approval_version is not null and inv.authorization_version is not null
       and ap.approval_version is distinct from inv.authorization_version then return 'invocation_version_mismatch'; end if;
  end if;

  -- Invocations linked only through aios_tool_invocations.approval_id are also expired by the job: they must be same-tenant.
  if exists (select 1 from public.aios_tool_invocations i where i.approval_id = ap.id and i.organization_id <> ap.organization_id) then
    return 'linked_invocation_organization_mismatch';
  end if;

  return null;
end; $$;

revoke all on function private.aios_approval_binding_defect(uuid) from public, anon, authenticated, service_role;
comment on function private.aios_approval_binding_defect(uuid) is 'Read-only. Returns a defect code when a pending approval would be refused by the approval integrity trigger (or crosses tenants), else NULL.';

create or replace function private.aios_expire_stale_approvals()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a record;
  v_inv uuid; v_inv_status text; v_task uuid; v_mission uuid; v_defect text;
  d_expired int; d_orphans int; d_tasks int; d_skipped int;
  v_expired int := 0; v_tasks_expired int := 0; v_orphans int := 0; v_skipped int := 0;
  v_invalid_n int := 0; v_error_n int := 0; v_record_fail int := 0;
  v_invalid jsonb := '[]'::jsonb;
begin
  for a in
    select ap.id, ap.invocation_id, ap.organization_id
    from public.aios_approvals ap
    where ap.status = 'pending'
      and ((ap.expires_at is not null and ap.expires_at <= now())
        or (ap.expires_at is null and ap.created_at < now() - interval '24 hours'))
    order by ap.created_at
    for update of ap skip locked
  loop
    v_defect := private.aios_approval_binding_defect(a.id);

    if v_defect is null then
      -- Per-record sub-transaction: an unforeseen failure rolls back only this record and never the batch.
      begin
        d_expired := 0; d_orphans := 0; d_tasks := 0; d_skipped := 0;
        v_inv := a.invocation_id; v_inv_status := null;
        if v_inv is null then
          select i.id into v_inv from public.aios_tool_invocations i where i.approval_id = a.id order by i.created_at desc limit 1;
        end if;
        if v_inv is not null then
          select i.status into v_inv_status from public.aios_tool_invocations i where i.id = v_inv for update;
        end if;

        if v_inv is not null and v_inv_status is distinct from 'requires_approval' then
          -- A linked invocation in any state other than requires_approval may be in flight: never expire its approval here.
          d_skipped := 1;
        else
          update public.aios_approvals
            set status = 'expired', reviewed_at = now(),
                approval_reason = coalesce(approval_reason, 'approval expired before a decision was made')
            where id = a.id and status = 'pending';

          if v_inv is null then
            d_orphans := 1;
          else
            v_task := null;
            update public.aios_tool_invocations
              set status = 'expired', completed_at = now(), error_code = 'APPROVAL_EXPIRED',
                  error_message = 'approval expired before a decision was made'
              where id = v_inv and status = 'requires_approval'
              returning task_id into v_task;
            d_expired := 1;

            if v_task is not null then
              v_mission := null;
              update public.aios_tasks
                set status = 'expired', failed_stage = 'approval_expired',
                    last_error = 'approval expired before a decision was made',
                    result = coalesce(result, '{}'::jsonb) || jsonb_build_object('error', 'approval_expired', 'invocation_id', v_inv)
                where id = v_task and status in ('blocked_pending_approval', 'running')
                returning mission_id into v_mission;
              if v_mission is not null then
                d_tasks := 1;
                update public.aios_missions m set status = 'failed', completed_at = now()
                  where m.id = v_mission and m.status in ('running', 'blocked_pending_approval')
                    and not exists (
                      select 1 from public.aios_tasks s
                      where s.mission_id = m.id
                        and s.status in ('queued','assigned','ready','running','approved','blocked_pending_approval'));
              end if;
            end if;
          end if;
        end if;

        v_expired := v_expired + d_expired; v_orphans := v_orphans + d_orphans;
        v_tasks_expired := v_tasks_expired + d_tasks; v_skipped := v_skipped + d_skipped;
      exception when others then
        v_defect := 'transition_error:' || sqlstate;
        v_error_n := v_error_n + 1;
      end;
    else
      v_invalid_n := v_invalid_n + 1;
    end if;

    if v_defect is not null then
      -- Reported in the return value and recorded durably (append-only; one row per approval, never rewritten).
      v_invalid := v_invalid || jsonb_build_array(jsonb_build_object('approval_id', a.id, 'defect', v_defect));
      begin
        insert into public.aios_backlog_dispositions
          (organization_id, entity_type, entity_id, classification, disposition, rationale, decided_by)
        values (a.organization_id, 'approval', a.id, 'needs_owner_review', 'manual_review',
                'Pending approval skipped by the convergence job because it cannot be transitioned safely (' || v_defect ||
                '). Record left unmodified; requires owner review. Detected automatically.',
                'job:aios_expire_stale_approvals')
        on conflict do nothing;
      exception when others then
        v_record_fail := v_record_fail + 1;
      end;
    end if;
  end loop;

  return jsonb_build_object('approvals_expired', v_expired, 'orphan_approvals_expired', v_orphans,
                            'tasks_expired', v_tasks_expired, 'skipped_in_flight', v_skipped,
                            'invalid_bindings_skipped', v_invalid_n, 'transition_errors_skipped', v_error_n,
                            'disposition_record_failures', v_record_fail, 'skipped_records', v_invalid);
end; $$;

revoke all on function private.aios_expire_stale_approvals() from public, anon, authenticated;
grant execute on function private.aios_expire_stale_approvals() to service_role;
comment on function private.aios_expire_stale_approvals() is 'Converges lapsed and legacy (NULL expires_at, >24h) pending approvals via either invocation link. Pre-checks bindings; skips and reports defective records; per-record sub-transaction so one failure never aborts the batch. Never touches an approval whose invocation is not requires_approval. Idempotent.';

-- Append-only manual-review disposition for each pending approval whose binding is currently defective (data-driven; no-op on a clean database).
insert into public.aios_backlog_dispositions
  (organization_id, entity_type, entity_id, classification, disposition, rationale, decided_by)
select ap.organization_id, 'approval', ap.id, 'needs_owner_review', 'manual_review',
       'Pending approval has an invalid binding (' || private.aios_approval_binding_defect(ap.id) ||
       '): the approval integrity trigger refuses every update to it, so the canonical job cannot expire it. Left unmodified; supersedes the earlier expire_via_canonical_job disposition for this approval. Requires owner decision.',
       'migration:20261102000000'
from public.aios_approvals ap
where ap.status = 'pending' and private.aios_approval_binding_defect(ap.id) is not null
on conflict do nothing;
