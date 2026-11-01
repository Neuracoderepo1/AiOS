-- Approvals default to a 15 minute expiry, but nothing converged the records once they lapsed. A task blocked on a lapsed
-- approval could never be resolved (aios_resolve_approval raises 'approval expired'), so it stayed blocked forever.
create or replace function private.aios_expire_stale_approvals()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a record;
  v_task uuid; v_mission uuid;
  v_expired int := 0; v_tasks_expired int := 0;
begin
  for a in
    select ap.id, ap.invocation_id
    from public.aios_approvals ap
    join public.aios_tool_invocations i on i.id = ap.invocation_id
    where ap.status = 'pending' and ap.expires_at is not null and ap.expires_at <= now()
      and i.status = 'requires_approval'
    for update of ap skip locked
  loop
    update public.aios_approvals
      set status = 'expired', reviewed_at = now(),
          approval_reason = coalesce(approval_reason, 'approval expired before a decision was made')
      where id = a.id and status = 'pending';

    v_task := null;
    update public.aios_tool_invocations
      set status = 'expired', completed_at = now(), error_code = 'APPROVAL_EXPIRED',
          error_message = 'approval expired before a decision was made'
      where id = a.invocation_id and status = 'requires_approval'
      returning task_id into v_task;
    v_expired := v_expired + 1;

    if v_task is not null then
      v_mission := null;
      update public.aios_tasks
        set status = 'expired', failed_stage = 'approval_expired',
            last_error = 'approval expired before a decision was made',
            result = coalesce(result, '{}'::jsonb) || jsonb_build_object('error', 'approval_expired', 'invocation_id', a.invocation_id)
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
  return jsonb_build_object('approvals_expired', v_expired, 'tasks_expired', v_tasks_expired);
end; $$;

revoke all on function private.aios_expire_stale_approvals() from public, anon, authenticated;
grant execute on function private.aios_expire_stale_approvals() to service_role;
comment on function private.aios_expire_stale_approvals() is 'Converges lapsed pending approvals: approval -> expired, invocation -> expired, blocked/running task -> expired. Idempotent.';

select cron.schedule('aios-expire-stale-approvals', '*/5 * * * *', $$select private.aios_expire_stale_approvals()$$);
