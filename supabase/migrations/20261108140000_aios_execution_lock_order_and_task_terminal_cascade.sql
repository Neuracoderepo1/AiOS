-- Execution-authority lock order + task-level terminal cascade.   STATUS: PROPOSED. Not deployed. Requires Human Director authorization.
--
-- Defects reproduced on real PostgreSQL by tests/concurrency/mission_task_races.sh (see docs/certification/closure/):
--   F-1  Lock-order inversion. The kernel authorizer locked invocation -> task -> mission, while the mission terminal cascade
--        (its triggering UPDATE already holds the mission row) locks mission -> approvals -> invocations -> tasks. Under contention
--        PostgreSQL aborted the MISSION CANCELLATION with 40P01 while the executor claimed 'executing'.
--   F-2  Withdrawing a TASK (cancelled/failed/expired/completed) did not cascade, leaving an 'approved'/'requires_approval'
--        invocation and a pending approval orphaned. (The kernel still refused to execute them; this is state hygiene, not a bypass.)
--
-- Single global lock order adopted by every function touched here:   mission -> task -> invocation -> approval.
-- No security check is removed or weakened; aios_assert_invocation_executable remains the authority and is unchanged.

-- 1. Authorizer prologue: take mission, then task, BEFORE the invocation row lock. Non-locking reads discover the chain.
create or replace function private.aios_lock_execution_chain(p_invocation_id uuid)
returns void language plpgsql security definer set search_path = '' as $f$
declare v_task uuid; v_mission uuid;
begin
  select task_id into v_task from public.aios_tool_invocations where id = p_invocation_id;
  if v_task is null then return; end if;
  select mission_id into v_mission from public.aios_tasks where id = v_task;
  if v_mission is not null then perform 1 from public.aios_missions where id = v_mission for share; end if;
  perform 1 from public.aios_tasks where id = v_task for share;
end $f$;
revoke all on function private.aios_lock_execution_chain(uuid) from public, anon, authenticated;
grant execute on function private.aios_lock_execution_chain(uuid) to service_role;

do $m$
declare d text; a constant text := 'select * into v from public.aios_tool_invocations where id = p_invocation_id for update;';
begin
  d := pg_get_functiondef('private.aios_kernel_authorize_invocation(uuid)'::regprocedure);
  if position('aios_lock_execution_chain' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception 'authorizer lock anchor not found'; end if;
  d := replace(d, a, E'perform private.aios_lock_execution_chain(p_invocation_id);\n  ' || a);
  execute d;
end $m$;

-- 2. Task terminal cascade (F-2). Runs AFTER the task row is updated; the task lock is already held, so the order is task -> invocation -> approval.
create or replace function private.aios_task_terminal_cascade()
returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  -- When the parent mission is itself terminal, the mission cascade owns the attribution (MISSION_TERMINAL); do not pre-empt it.
  if new.status in ('cancelled','failed','expired','completed') and old.status is distinct from new.status
     and coalesce((select m.status from public.aios_missions m where m.id = new.mission_id), 'running') not in ('cancelled','failed','expired','completed') then
    update public.aios_tool_invocations i set status = 'cancelled', completed_at = now(),
           error_code = 'TASK_TERMINAL', error_message = 'task became ' || new.status
     where i.task_id = new.id and i.organization_id = new.organization_id and i.status in ('requires_approval','approved');
    update public.aios_approvals ap set status = 'expired', reviewed_at = now()
     where ap.task_id = new.id and ap.status = 'pending';
  end if;
  return new;
end $f$;
revoke all on function private.aios_task_terminal_cascade() from public, anon, authenticated;
drop trigger if exists trg_aios_task_terminal_cascade on public.aios_tasks;
create trigger trg_aios_task_terminal_cascade after update of status on public.aios_tasks
  for each row execute function private.aios_task_terminal_cascade();

-- 3. Mission cascade re-ordered to the global order: tasks first (their cascade then reaches invocations and approvals), then a sweep
--    for rows of tasks that were ALREADY terminal. Same effects as before; only the acquisition order changes.
create or replace function private.aios_mission_terminal_cascade()
returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  if new.status in ('cancelled','failed','expired','completed') and old.status is distinct from new.status then
    update public.aios_tasks set status = 'cancelled'
     where mission_id = new.id and status in ('queued','assigned','ready','running','approved','blocked_pending_approval');
    update public.aios_tool_invocations i set status = 'cancelled', completed_at = now(),
           error_code = 'MISSION_TERMINAL', error_message = 'parent mission became ' || new.status
     where i.status in ('requires_approval','approved') and i.task_id in (select id from public.aios_tasks where mission_id = new.id);
    update public.aios_approvals ap set status = 'expired', reviewed_at = now()
     where ap.status = 'pending' and ap.task_id in (select id from public.aios_tasks where mission_id = new.id);
  end if;
  return new;
end $f$;
