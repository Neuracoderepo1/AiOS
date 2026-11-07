-- 1. Kernel executability gate (task + parent mission), fail-closed
create or replace function private.aios_assert_invocation_executable(p_task_id uuid)
returns void language plpgsql security definer set search_path = '' as $f$
declare v_ts text; v_mid uuid; v_ms text;
begin
  if p_task_id is null then return; end if;
  select status, mission_id into v_ts, v_mid from public.aios_tasks where id = p_task_id for share;
  if not found then raise exception 'task not found' using errcode='P0002'; end if;
  if v_ts not in ('queued','assigned','ready','running','approved') then
    raise exception 'task is not executable: %', v_ts using errcode='42501';
  end if;
  if v_mid is null then return; end if;
  select status into v_ms from public.aios_missions where id = v_mid for share;
  if v_ms is null or v_ms not in ('queued','running') then
    raise exception 'parent mission is not executable: %', coalesce(v_ms,'missing') using errcode='42501';
  end if;
end $f$;

-- 2. Wire the gate into the kernel directly after the invocation row lock
do $m$
declare d text;
begin
  d := pg_get_functiondef('private.aios_kernel_authorize_invocation(uuid)'::regprocedure);
  if position('aios_assert_invocation_executable' in d) > 0 then return; end if;
  if position('-- 1. CURRENT AGENT' in d) = 0 then raise exception 'anchor not found'; end if;
  d := replace(d, '-- 1. CURRENT AGENT',
    E'perform private.aios_assert_invocation_executable(v.task_id);\n\n  -- 1. CURRENT AGENT');
  execute d;
end $m$;

-- 3. Cascade when a mission becomes terminal
create or replace function private.aios_mission_terminal_cascade()
returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  if new.status in ('cancelled','failed','expired','completed') and old.status is distinct from new.status then
    update public.aios_approvals ap set status='expired', reviewed_at=now()
      where ap.status='pending' and ap.task_id in (select id from public.aios_tasks where mission_id=new.id);
    update public.aios_tool_invocations i set status='cancelled', completed_at=now(),
           error_code='MISSION_TERMINAL', error_message='parent mission became '||new.status
      where i.status in ('requires_approval','approved')
        and i.task_id in (select id from public.aios_tasks where mission_id=new.id);
    update public.aios_tasks set status='cancelled'
      where mission_id=new.id and status in ('queued','assigned','ready','running','approved','blocked_pending_approval');
  end if;
  return new;
end $f$;

drop trigger if exists trg_aios_mission_terminal_cascade on public.aios_missions;
create trigger trg_aios_mission_terminal_cascade after update of status on public.aios_missions
  for each row execute function private.aios_mission_terminal_cascade();

-- 4. State-transition boundary: no live task under a terminal mission (insert or transition)
create or replace function private.aios_task_mission_gate()
returns trigger language plpgsql security definer set search_path = '' as $f$
declare v_ms text;
begin
  if new.mission_id is not null
     and new.status in ('queued','assigned','ready','running','approved')
     and (tg_op = 'INSERT' or new.status is distinct from old.status or new.mission_id is distinct from old.mission_id) then
    select status into v_ms from public.aios_missions where id = new.mission_id;
    if v_ms in ('completed','failed','cancelled','expired') then
      raise exception 'parent mission is terminal (%): task cannot enter %', v_ms, new.status using errcode='42501';
    end if;
  end if;
  return new;
end $f$;

drop trigger if exists trg_aios_task_mission_gate on public.aios_tasks;
create trigger trg_aios_task_mission_gate before insert or update of status, mission_id on public.aios_tasks
  for each row execute function private.aios_task_mission_gate();

-- 5. Audit ledger: block TRUNCATE
revoke truncate on public.aios_audit_events from service_role, authenticated, anon;
drop trigger if exists trg_aios_audit_no_truncate on public.aios_audit_events;
create trigger trg_aios_audit_no_truncate before truncate on public.aios_audit_events
  for each statement execute function private.aios_audit_immutable();
