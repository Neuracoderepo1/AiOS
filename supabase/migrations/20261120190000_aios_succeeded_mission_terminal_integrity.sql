-- Keep the succeeded terminal state consistent across mission cascades and task writes.
-- Successful completed tasks remain completed; residual live invocations and approvals
-- are closed, and no new live task may be attached to a succeeded mission.

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
    select status into v_ms
      from public.aios_missions
     where id = new.mission_id;

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
