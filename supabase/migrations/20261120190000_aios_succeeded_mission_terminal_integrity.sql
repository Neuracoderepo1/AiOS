-- Keep the succeeded terminal state consistent across mission cascades and task writes.
-- Successful completed tasks remain completed; residual live invocations and approvals
-- are closed, and no new live task may be attached to a succeeded mission.

-- The RPC already treats succeeded as terminal. Make that state reachable only
-- from an active execution path, with the same completed-task precondition as completed.
create or replace function private.aios_mission_status_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $f$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if not (
      (old.status = 'queued' and new.status in ('running','cancelled','expired'))
      or (old.status = 'running' and new.status in ('blocked_pending_approval','completed','failed','cancelled','expired'))
      or (old.status = 'blocked_pending_approval' and new.status in ('running','completed','failed','cancelled','expired'))
    ) then
      raise exception 'invalid mission state transition: % -> %', old.status, new.status;
    end if;
  end if;

  if new.status = 'completed' and exists (
    select 1 from public.aios_tasks t
     where t.mission_id = new.id and t.status <> 'completed'
  ) then
    raise exception 'mission cannot complete while tasks remain incomplete';
  end if;

  if new.status = 'succeeded' and exists (
    select 1 from public.aios_tasks t
     where t.mission_id = new.id and t.status <> 'completed'
  ) then
    raise exception 'mission cannot succeed while tasks remain incomplete';
  end if;

  if new.status = 'running' and new.started_at is null then
    new.started_at = now();
  end if;
  if new.status in ('completed','succeeded','failed','cancelled','expired') and new.completed_at is null then
    new.completed_at = now();
  end if;
  return new;
end
$f$;

create or replace function private.aios_mission_terminal_cascade()
returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  if new.status in ('cancelled','failed','expired','completed','succeeded')
     and old.status is distinct from new.status then
    -- Preserve the established mission -> task -> invocation -> approval lock order.
    update public.aios_tasks
       set status = 'cancelled'
     where mission_id = new.id
       and status in ('queued','assigned','ready','running','approved','blocked_pending_approval');

    update public.aios_tool_invocations i
       set status = 'cancelled',
           completed_at = now(),
           error_code = 'MISSION_TERMINAL',
           error_message = 'parent mission became ' || new.status
     where i.status in ('requires_approval','approved')
       and i.task_id in (select id from public.aios_tasks where mission_id = new.id);

    update public.aios_approvals ap
       set status = 'expired',
           reviewed_at = now()
     where ap.status = 'pending'
       and ap.task_id in (select id from public.aios_tasks where mission_id = new.id);
  end if;
  return new;
end
$f$;

create or replace function private.aios_task_mission_gate()
returns trigger language plpgsql security definer set search_path = '' as $f$
declare v_ms text;
begin
  if new.mission_id is not null
     and new.status in ('queued','assigned','ready','running','approved','blocked_pending_approval')
     and (tg_op = 'INSERT' or new.status is distinct from old.status or new.mission_id is distinct from old.mission_id) then
    -- INSERT serializes with mission cancellation before the FK check. Cancellation
    -- holds FOR UPDATE; FOR SHARE makes the insert either visible to the cascade or
    -- reject against the committed terminal state. Do not lock the parent on UPDATE:
    -- the task row is already locked there, which would invert mission -> task order.
    if tg_op = 'INSERT' then
      select status into v_ms from public.aios_missions where id = new.mission_id for share;
    else
      select status into v_ms from public.aios_missions where id = new.mission_id;
    end if;

    if v_ms in ('completed','failed','cancelled','expired','succeeded') then
      raise exception 'parent mission is terminal (%): task cannot enter %', v_ms, new.status
        using errcode='42501';
    end if;
  end if;
  return new;
end
$f$;

drop trigger if exists trg_aios_mission_terminal_cascade on public.aios_missions;
create trigger trg_aios_mission_terminal_cascade
  after update of status on public.aios_missions
  for each row execute function private.aios_mission_terminal_cascade();

drop trigger if exists trg_aios_task_mission_gate on public.aios_tasks;
create trigger trg_aios_task_mission_gate
  before insert or update of status, mission_id on public.aios_tasks
  for each row execute function private.aios_task_mission_gate();

-- Advance only the three intentionally replaced guard-function fingerprints.
-- Unrelated trigger definitions and registry entries remain untouched.
do $pin$
declare v_rows integer;
begin
  update private.aios_guarded_triggers
     set expected_function_fp = private.aios_function_fingerprint(expected_function::regprocedure),
         registered_at = clock_timestamp(), registered_by = session_user
   where (schema_name, table_name, trigger_name, expected_function) in (
     ('public','aios_missions','trg_aios_mission_status_guard','private.aios_mission_status_guard()'),
     ('public','aios_missions','trg_aios_mission_terminal_cascade','private.aios_mission_terminal_cascade()'),
     ('public','aios_tasks','trg_aios_task_mission_gate','private.aios_task_mission_gate()')
   );
  get diagnostics v_rows = row_count;
  if v_rows <> 3 then raise exception 'expected exactly three guarded mission/task function fingerprints, updated %', v_rows; end if;
end
$pin$;
