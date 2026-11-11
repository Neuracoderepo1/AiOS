-- Close Agent 003 findings 003-02, 003-06, 003-07 and 003-08.
-- Proposed branch migration only. No hosted database has been changed.

-- A single resolver is used by phase-one pre-lock and phase-two expiry.
-- Lock order: mission -> task -> invocation -> approval.
create or replace function private.aios_lock_approval_chain(p_approval_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $f$
declare
  v_inv uuid;
  v_task uuid;
  v_mission uuid;
  v_inv_org uuid;
  v_inv_approval_snapshot uuid;
  v_approval_inv_snapshot uuid;
  v_task_org uuid;
  v_mission_org uuid;
  v_approval_org uuid;
  v_current_inv uuid;
  v_current_task uuid;
  v_current_mission uuid;
  v_current_inv_org uuid;
  v_current_task_org uuid;
  v_current_mission_org uuid;
  v_current_approval_inv uuid;
  v_current_inv_approval uuid;
begin
  v_inv := private.aios_resolve_approval_invocation(p_approval_id);

  if v_inv is null then
    perform 1 from public.aios_approvals where id = p_approval_id for update;
    if not found then return; end if;
    if private.aios_resolve_approval_invocation(p_approval_id) is not null then
      raise exception 'approval invocation binding changed while locking' using errcode = '40001';
    end if;
    return;
  end if;

  select invocation_id into v_approval_inv_snapshot
    from public.aios_approvals where id = p_approval_id;
  if not found then
    raise exception 'resolved approval disappeared' using errcode = '40001';
  end if;

  select task_id, organization_id, approval_id
    into v_task, v_inv_org, v_inv_approval_snapshot
    from public.aios_tool_invocations where id = v_inv;
  if not found then
    raise exception 'resolved approval invocation disappeared' using errcode = '40001';
  end if;

  if v_task is not null then
    select mission_id, organization_id into v_mission, v_task_org
      from public.aios_tasks where id = v_task;
    if not found then
      raise exception 'resolved approval task disappeared' using errcode = '40001';
    end if;
    if v_mission is not null then
      select organization_id into v_mission_org
        from public.aios_missions where id = v_mission for no key update;
      if not found then
        raise exception 'resolved approval mission disappeared' using errcode = '40001';
      end if;
    end if;
    perform 1 from public.aios_tasks where id = v_task for no key update;
  end if;

  perform 1 from public.aios_tool_invocations where id = v_inv for update;
  perform 1 from public.aios_approvals where id = p_approval_id for update;
  if not found then
    raise exception 'approval disappeared while locking its chain' using errcode = '40001';
  end if;

  select invocation_id, organization_id into v_current_approval_inv, v_approval_org
    from public.aios_approvals where id = p_approval_id;
  v_current_inv := private.aios_resolve_approval_invocation(p_approval_id);

  select task_id, organization_id, approval_id
    into v_current_task, v_current_inv_org, v_current_inv_approval
    from public.aios_tool_invocations where id = v_inv;
  if not found then
    raise exception 'locked invocation disappeared' using errcode = '40001';
  end if;

  if v_current_inv is distinct from v_inv
     or v_current_approval_inv is distinct from v_approval_inv_snapshot
     or v_current_task is distinct from v_task
     or v_current_inv_org is distinct from v_inv_org
     or v_current_inv_approval is distinct from v_inv_approval_snapshot then
    raise exception 'approval invocation binding changed while locking' using errcode = '40001';
  end if;

  if v_current_approval_inv is not null then
    if v_current_approval_inv is distinct from v_inv then
      raise exception 'approval direct invocation binding changed while locking' using errcode = '40001';
    end if;
  elsif v_current_inv_approval is distinct from p_approval_id then
    raise exception 'approval reverse invocation binding changed while locking' using errcode = '40001';
  end if;

  if v_task is not null then
    select mission_id, organization_id into v_current_mission, v_current_task_org
      from public.aios_tasks where id = v_task;
    if not found or v_current_mission is distinct from v_mission
       or v_current_task_org is distinct from v_task_org then
      raise exception 'approval task/mission binding changed while locking' using errcode = '40001';
    end if;
    if v_mission is not null then
      select organization_id into v_current_mission_org
        from public.aios_missions where id = v_mission;
      if not found or v_current_mission_org is distinct from v_mission_org then
        raise exception 'approval mission organization changed while locking' using errcode = '40001';
      end if;
    end if;
    if v_task_org is distinct from v_inv_org
       or v_approval_org is distinct from v_inv_org
       or (v_mission is not null and v_mission_org is distinct from v_inv_org) then
      raise exception 'approval chain organization mismatch' using errcode = '23514';
    end if;
  elsif v_approval_org is distinct from v_inv_org then
    raise exception 'approval/invocation organization mismatch' using errcode = '23514';
  end if;
end
$f$;
revoke all on function private.aios_lock_approval_chain(uuid) from public, anon, authenticated;
grant execute on function private.aios_lock_approval_chain(uuid) to service_role;

-- The audit trigger takes this same advisory key. Acquire every organization key
-- in a single global order only after all row locks have been acquired.
create or replace function private.aios_prelock_audit_organizations(p_organization_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $f$
declare r record;
begin
  for r in
    select distinct x.organization_id
    from unnest(coalesce(p_organization_ids, '{}'::uuid[])) as x(organization_id)
    where x.organization_id is not null
    order by x.organization_id
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(coalesce(r.organization_id::text, ''), 0)
    );
  end loop;
end
$f$;
revoke all on function private.aios_prelock_audit_organizations(uuid[]) from public, anon, authenticated;
grant execute on function private.aios_prelock_audit_organizations(uuid[]) to service_role;

-- Phase two must use the exact resolver that phase one used.
-- Both batch jobs pre-acquire all relevant audit-org locks in UUID order after
-- all mission/task/invocation/approval row locks, before their first audit write.
do $patch$
declare
  d text;
  n text;
begin
  d := pg_get_functiondef('private.aios_expire_stale_approvals()'::regprocedure);
  n := replace(
    d,
    'select i.id into v_inv from public.aios_tool_invocations i where i.approval_id = a.id order by i.created_at desc limit 1;',
    'select private.aios_resolve_approval_invocation(a.id) into v_inv;'
  );
  if n = d then
    raise exception 'expiry resolver patch anchor not found';
  end if;
  d := n;
  n := replace(
    d,
    'perform private.aios_prelock_approvals_batch(v_ids);',
    'perform private.aios_prelock_approvals_batch(v_ids);' || E'\n  perform private.aios_prelock_audit_organizations((select coalesce(array_agg(distinct organization_id order by organization_id), ''{}''::uuid[]) from public.aios_approvals where id = any(v_ids)));'
  );
  if n = d then
    raise exception 'expiry audit-org prelock anchor not found';
  end if;
  execute n;

  d := pg_get_functiondef('private.aios_reap_stale_tasks(interval)'::regprocedure);
  n := replace(
    d,
    'perform private.aios_prelock_tasks_batch(v_ids);',
    'perform private.aios_prelock_tasks_batch(v_ids);' || E'\n  perform private.aios_prelock_audit_organizations((select coalesce(array_agg(distinct organization_id order by organization_id), ''{}''::uuid[]) from public.aios_tasks where id = any(v_ids)));'
  );
  if n = d then
    raise exception 'reaper audit-org prelock anchor not found';
  end if;
  execute n;
end
$patch$;

-- Preserve the historical payload and digest byte-for-byte. Only pin the trigger
-- execution TimeZone so non-UTC session settings cannot change timestamp text.
create or replace function private.aios_audit_append()
returns trigger
language plpgsql
security definer
set search_path = ''
set timezone = 'UTC'
as $$
declare
  v_prev text;
  v_last_created timestamptz;
  v_payload text;
begin
  perform pg_advisory_xact_lock(hashtextextended(coalesce(new.organization_id::text,''),0));
  select event_hash,created_at into v_prev,v_last_created
    from public.aios_audit_events
    where organization_id=new.organization_id
    order by created_at desc,id desc limit 1;
  if v_last_created is not null and new.created_at<=v_last_created then
    new.created_at=v_last_created+interval '1 microsecond';
  end if;
  new.previous_event_hash=coalesce(v_prev,'GENESIS:'||new.organization_id::text);
  v_payload=jsonb_build_object(
    'id',new.id,'organization_id',new.organization_id,'actor_user_id',new.actor_user_id,
    'actor_type',new.actor_type,'agent_id',new.agent_id,'mission_id',new.mission_id,
    'task_id',new.task_id,'invocation_id',new.invocation_id,'event_type',new.event_type,
    'previous_state',new.previous_state,'new_state',new.new_state,'tool_name',new.tool_name,
    'risk_level',new.risk_level,'arguments_hash',new.arguments_hash,'result_hash',new.result_hash,
    'approval_id',new.approval_id,'created_at',new.created_at,'metadata',new.metadata,
    'previous_event_hash',new.previous_event_hash
  )::text||new.previous_event_hash;
  new.event_hash=encode(extensions.digest(v_payload,'sha256'),'hex');
  return new;
end;
$$;


-- The restoration guard intentionally fingerprints trigger functions. This migration
-- changes the registered audit append function's GUC (UTC) without changing the
-- trigger definition; advance exactly that one expected function fingerprint.
do $pin$
declare v_rows int;
begin
  update private.aios_guarded_triggers
     set expected_function_fp = private.aios_function_fingerprint('private.aios_audit_append()'::regprocedure),
         registered_at = clock_timestamp(),
         registered_by = session_user
   where schema_name = 'public'
     and table_name = 'aios_audit_events'
     and trigger_name = 'trg_aios_audit_hash'
     and expected_function = 'private.aios_audit_append()';
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'expected exactly one guarded audit append trigger registration, updated %', v_rows;
  end if;
end
$pin$;
