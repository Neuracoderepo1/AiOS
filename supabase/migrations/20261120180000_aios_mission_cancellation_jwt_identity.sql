-- Bind mission cancellation to the authenticated JWT identity.
-- The previous two-argument RPC trusted a caller-supplied actor UUID. Replace it with
-- auth.uid() and serialize membership changes before locking the mission row.
drop function if exists public.aios_cancel_mission(uuid, uuid);
drop function if exists private.aios_cancel_mission(uuid, uuid);

create or replace function public.aios_cancel_mission(p_mission_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_organization_id uuid;
  v_locked_organization_id uuid;
  v_status text;
  v_role text;
  v_rows integer;
begin
  if v_actor is null then
    raise exception 'authenticated user identity required' using errcode = '42501';
  end if;
  if p_mission_id is null then
    raise exception 'mission_id is required' using errcode = '22023';
  end if;

  -- Discover tenant without taking the mission lock. A shared row lock
  -- blocks concurrent role revocation/deletion while allowing independent
  -- cancellations by the same administrator to proceed concurrently.
  select m.organization_id
    into v_organization_id
    from public.aios_missions m
   where m.id = p_mission_id;
  if not found then
    return jsonb_build_object('outcome', 'not_found', 'mission_id', p_mission_id);
  end if;

  select om.role::text
    into v_role
    from public.aios_organization_members om
   where om.organization_id = v_organization_id
     and om.user_id = v_actor
   for share;
  if not found or v_role not in ('owner', 'admin', 'administrator') then
    raise exception 'organization owner/admin authorization required' using errcode = '42501';
  end if;

  select m.organization_id, m.status
    into v_locked_organization_id, v_status
    from public.aios_missions m
   where m.id = p_mission_id
   for update;
  if not found then
    return jsonb_build_object('outcome', 'not_found', 'mission_id', p_mission_id);
  end if;
  if v_locked_organization_id is distinct from v_organization_id then
    raise exception 'mission organization changed during cancellation authorization' using errcode = '40001';
  end if;

  if v_status in ('completed', 'succeeded', 'failed', 'cancelled', 'expired') then
    return jsonb_build_object(
      'outcome', 'already_terminal',
      'mission_id', p_mission_id,
      'status', v_status
    );
  end if;

  if v_status not in ('queued', 'running', 'blocked_pending_approval') then
    return jsonb_build_object(
      'outcome', 'not_cancellable',
      'mission_id', p_mission_id,
      'status', v_status
    );
  end if;

  update public.aios_missions
     set status = 'cancelled',
         completed_at = coalesce(completed_at, clock_timestamp())
   where id = p_mission_id
     and status = v_status;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'mission state changed unexpectedly during cancellation' using errcode = '40001';
  end if;

  insert into public.aios_audit_events(
    organization_id, actor_user_id, actor_type, mission_id,
    event_type, risk_level, action, decision, previous_state, new_state, metadata
  ) values (
    v_organization_id, v_actor, 'user', p_mission_id,
    'mission_cancellation_requested', 'low', 'cancel_mission', 'allow',
    v_status, 'cancelled',
    jsonb_build_object('mission_id', p_mission_id, 'requested_by', v_actor)
  );

  return jsonb_build_object(
    'outcome', 'cancelled',
    'mission_id', p_mission_id,
    'status', 'cancelled',
    'previous_status', v_status
  );
end
$fn$;

revoke all on function public.aios_cancel_mission(uuid) from public, anon, service_role;
grant execute on function public.aios_cancel_mission(uuid) to authenticated;

comment on function public.aios_cancel_mission(uuid) is
  'Authenticated owner/admin cancellation. Actor is derived only from auth.uid(); terminal missions return already_terminal without mutation.';
