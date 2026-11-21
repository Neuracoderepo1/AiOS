-- Keep the legacy 'succeeded' mission state consistent across mission cascades and task writes.
--
-- State-machine decision (F-40-07): 'succeeded' is a LEGACY, SEED-ONLY terminal state. 'completed'
-- is the sole success terminal reachable by transition, and nothing in the repository (Edge
-- Functions, RPCs, reaper) writes mission status 'succeeded'. A mission can exist in 'succeeded'
-- only by direct INSERT (historical/seeded rows). This migration therefore does NOT add an
-- active -> succeeded transition: the guard below rejects every transition INTO 'succeeded' and
-- every transition OUT of it. What it guarantees is that a mission already in 'succeeded' is
-- treated as terminal everywhere: residual live invocations/approvals are closed by the cascade
-- and no new live task may be attached to it (task gate). tests/sql/19 pins both facts.
-- Pre-existing 'succeeded' rows with live children are NOT swept: the migration aborts instead
-- (see the precondition below; tests/sql/20).
--
-- Fail-closed precondition for historical data. The cascade below fires only on a status CHANGE and
-- the task gate only on task writes, so a mission that is ALREADY 'succeeded' keeps any live
-- children it has. Refuse to apply this migration over such rows rather than silently mutating
-- historical data during a hosted migration; an operator must resolve them first (the error
-- reports the counts). Hosted baseline at authoring time: zero 'succeeded' missions.
-- This check is invoker-rights and executable by no client role.
create or replace function private.aios_assert_no_residual_succeeded_children()
returns void
language plpgsql
security invoker
set search_path = ''
as $f$
declare
  v_tasks bigint;
  v_inv bigint;
  v_appr bigint;
begin
  select count(*) into v_tasks
    from public.aios_tasks t
    join public.aios_missions m on m.id = t.mission_id
   where m.status = 'succeeded'
     and t.status in ('queued','assigned','ready','running','approved','blocked_pending_approval');

  select count(*) into v_inv
    from public.aios_tool_invocations i
    join public.aios_tasks t on t.id = i.task_id
    join public.aios_missions m on m.id = t.mission_id
   where m.status = 'succeeded'
     and i.status not in ('succeeded','failed','denied','cancelled','expired');

  select count(*) into v_appr
    from public.aios_approvals a
    join public.aios_tasks t on t.id = a.task_id
    join public.aios_missions m on m.id = t.mission_id
   where m.status = 'succeeded'
     and a.status = 'pending';

  if v_tasks + v_inv + v_appr > 0 then
    raise exception 'succeeded missions have residual live children (tasks=%, invocations=%, approvals=%): resolve them before applying this migration',
      v_tasks, v_inv, v_appr using errcode = '55000';
  end if;
end
$f$;
revoke all on function private.aios_assert_no_residual_succeeded_children() from public, anon, authenticated, service_role;
select private.aios_assert_no_residual_succeeded_children();

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
    -- reject against the committed terminal state.
    -- Re-parenting a live task (mission_id change) must also serialize with cancellation of
    -- the destination mission, otherwise it could slip past the cascade. The task row is
    -- already locked in UPDATE, so a blocking parent lock would invert the global
    -- mission -> task order. FOR SHARE NOWAIT fails closed (55P03) instead of waiting, so
    -- it cannot deadlock. Plain status transitions keep the unlocked read.
    if tg_op = 'INSERT' then
      select status into v_ms from public.aios_missions where id = new.mission_id for share;
    elsif new.mission_id is distinct from old.mission_id then
      select status into v_ms from public.aios_missions where id = new.mission_id for share nowait;
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
