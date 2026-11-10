-- Approval / expiry / reaper paths adopt the single global lock order introduced by 20261108140000:
--     mission -> task -> invocation -> approval        (STATUS: PROPOSED. Not deployed. Requires Human Director authorization.)
--
-- Why: 20261108140000 re-ordered the authorizer and the mission cascade to that order, but aios_resolve_approval and
-- aios_expire_stale_approvals still lock approval -> invocation -> task -> mission, and aios_reap_stale_tasks locks task -> mission.
-- That is the inverse order, so an approval resolution racing the authorizer or a mission cancel could deadlock (40P01).
-- This migration changes ONLY lock acquisition order. No validation, authorization or state transition is added, removed or weakened.
--
-- Mechanism: every function below is patched in place (anchor-checked, idempotent) rather than rewritten, so its logic stays byte-identical.

create or replace function private.aios_lock_approval_chain(p_approval_id uuid)
returns void language plpgsql security definer set search_path = '' as $f$
declare v_inv uuid; v_task uuid; v_mission uuid;
begin
  -- Non-locking reads discover the chain; the caller re-validates every fact under the locks it then takes.
  select invocation_id into v_inv from public.aios_approvals where id = p_approval_id;
  if v_inv is null then
    select id into v_inv from public.aios_tool_invocations where approval_id = p_approval_id order by created_at desc limit 1;
  end if;
  if v_inv is null then return; end if;
  select task_id into v_task from public.aios_tool_invocations where id = v_inv;
  if v_task is not null then
    select mission_id into v_mission from public.aios_tasks where id = v_task;
    if v_mission is not null then perform 1 from public.aios_missions where id = v_mission for no key update; end if;
    perform 1 from public.aios_tasks where id = v_task for no key update;
  end if;
  perform 1 from public.aios_tool_invocations where id = v_inv for update;
end $f$;
revoke all on function private.aios_lock_approval_chain(uuid) from public, anon, authenticated;
grant execute on function private.aios_lock_approval_chain(uuid) to service_role;

do $m$
declare d text; n text;
begin
  -- 1. aios_resolve_approval: take mission -> task -> invocation BEFORE the approval row.
  d := pg_get_functiondef('private.aios_resolve_approval(uuid,text,uuid,text)'::regprocedure);
  if position('aios_lock_approval_chain' in d) = 0 then
    n := regexp_replace(d, '(SELECT\s+\*\s+INTO\s+a\s+FROM\s+public\.aios_approvals\s+WHERE\s+id\s*=\s*p_approval_id\s+FOR\s+UPDATE\s*;)',
                        E'PERFORM private.aios_lock_approval_chain(p_approval_id);\n  \\1');
    if n = d then raise exception 'resolve_approval lock anchor not found'; end if;
    execute n;
  end if;

  -- 2. aios_expire_stale_approvals: the cursor no longer locks approvals first. Per record: lock the chain, then re-confirm the approval
  --    is still pending and lapsed while locking it (skip locked), exactly the predicate the cursor used.
  d := pg_get_functiondef('private.aios_expire_stale_approvals()'::regprocedure);
  if position('aios_lock_approval_chain' in d) = 0 then
    n := regexp_replace(d, 'for\s+update\s+of\s+ap\s+skip\s+locked\s+loop', 'loop');
    if n = d then raise exception 'expire_stale_approvals cursor anchor not found'; end if;
    d := n;
    n := regexp_replace(d, '(d_expired\s*:=\s*0\s*;\s*d_orphans\s*:=\s*0\s*;\s*d_tasks\s*:=\s*0\s*;\s*d_skipped\s*:=\s*0\s*;)',
      E'\\1\n      perform private.aios_lock_approval_chain(a.id);\n'
      || E'      perform 1 from public.aios_approvals ap2 where ap2.id = a.id and ap2.status = ''pending''\n'
      || E'        and ((ap2.expires_at is not null and ap2.expires_at <= now()) or (ap2.expires_at is null and ap2.created_at < now() - interval ''24 hours''))\n'
      || E'        for update skip locked;\n'
      || E'      if not found then continue; end if;\n');
    if n = d then raise exception 'expire_stale_approvals body anchor not found'; end if;
    execute n;
  end if;

  -- 3. aios_reap_stale_tasks: mission before task. Same re-confirmation of the original predicate under the task lock.
  d := pg_get_functiondef('private.aios_reap_stale_tasks(interval)'::regprocedure);
  if position('for no key update' in d) = 0 then
    n := regexp_replace(d, 'for\s+update\s+skip\s+locked\s+loop', 'loop');
    if n = d then raise exception 'reap_stale_tasks cursor anchor not found'; end if;
    d := n;
    n := regexp_replace(d, '(loop\s+)(select\s+i\.id,\s*i\.status\s+into\s+inv)',
      E'\\1if r.mission_id is not null then perform 1 from public.aios_missions where id = r.mission_id for no key update; end if;\n'
      || E'    perform 1 from public.aios_tasks t2 where t2.id = r.id and t2.status = ''running'' and t2.updated_at < now() - p_max_age for update skip locked;\n'
      || E'    if not found then continue; end if;\n    \\2');
    if n = d then raise exception 'reap_stale_tasks body anchor not found'; end if;
    execute n;
  end if;
end $m$;
