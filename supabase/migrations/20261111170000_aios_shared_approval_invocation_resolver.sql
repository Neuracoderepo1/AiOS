-- Finding 003-02: make the phase-one and phase-two reverse-link resolver identical.
-- Status: PROPOSED, NOT DEPLOYED. Requires Human Director authorization.
-- A shared resolver makes the tie-break a single implementation contract.
create or replace function private.aios_resolve_approval_invocation(p_approval_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $f$
  select coalesce(
    (select ap.invocation_id
       from public.aios_approvals ap
      where ap.id = p_approval_id),
    (select i.id
       from public.aios_tool_invocations i
      where i.approval_id = p_approval_id
      order by i.created_at desc, i.id desc
      limit 1)
  )
$f$;
revoke all on function private.aios_resolve_approval_invocation(uuid) from public, anon, authenticated;
grant execute on function private.aios_resolve_approval_invocation(uuid) to service_role;

create or replace function private.aios_lock_approval_chain(p_approval_id uuid)
returns void language plpgsql security definer set search_path = '' as $f$
declare v_inv uuid; v_task uuid; v_mission uuid;
begin
  -- Discover through the exact resolver also used by phase-one batch pre-lock.
  select private.aios_resolve_approval_invocation(p_approval_id) into v_inv;
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

create or replace function private.aios_prelock_approvals_batch(p_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $f$
declare r record; v_last_mission uuid := null;
begin
  -- Resolve with the same shared function as phase two, then sort by the actual chain.
  for r in
    select ap.id as approval_id, i.id as invocation_id, i.task_id, t.mission_id
    from public.aios_approvals ap
    left join lateral (
      select candidate.id, candidate.task_id
      from public.aios_tool_invocations candidate
      where candidate.id = private.aios_resolve_approval_invocation(ap.id)
    ) i on true
    left join public.aios_tasks t on t.id = i.task_id
    where ap.id = any(p_ids)
    order by t.mission_id nulls last, t.id nulls last, i.id nulls last, ap.id
  loop
    if r.mission_id is not null then
      if r.mission_id is distinct from v_last_mission then
        perform private.aios_lock_mission_subtree(r.mission_id);
        v_last_mission := r.mission_id;
      end if;
    else
      perform private.aios_lock_approval_chain(r.approval_id);
    end if;
  end loop;
end $f$;
revoke all on function private.aios_prelock_approvals_batch(uuid[]) from public, anon, authenticated;
grant execute on function private.aios_prelock_approvals_batch(uuid[]) to service_role;
