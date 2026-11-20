-- Owner/admin mission cancellation contract. Candidate-only until reviewed and separately authorized for deployment.
-- Lock order: mission first; the existing terminal cascade then performs its established task/invocation/approval work.
create or replace function private.aios_cancel_mission(p_mission_id uuid, p_actor_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_organization_id uuid;
  v_status text;
begin
  if p_mission_id is null or p_actor_user_id is null then
    raise exception 'mission_id and actor_user_id are required' using errcode = '22023';
  end if;

  select m.organization_id, m.status
    into v_organization_id, v_status
    from public.aios_missions m
   where m.id = p_mission_id
   for update;

  if not found then
    return jsonb_build_object('outcome', 'not_found', 'mission_id', p_mission_id);
  end if;

  -- Re-check authority inside the transaction. The Edge Function check is not the security boundary.
  if not exists (
    select 1
      from public.aios_organization_members om
     where om.organization_id = v_organization_id
       and om.user_id = p_actor_user_id
       and om.role in ('owner', 'admin')
  ) then
    raise exception 'owner or admin authorization required' using errcode = '42501';
  end if;

  if v_status in ('completed', 'failed', 'cancelled', 'expired') then
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

  if not found then
    -- Defensive: the row is locked, so this should be unreachable unless a future trigger rewrites state.
    raise exception 'mission state changed unexpectedly during cancellation' using errcode = '40001';
  end if;

  insert into public.aios_audit_events(
    organization_id, actor_user_id, actor_type, mission_id,
    event_type, risk_level, action, decision, previous_state, new_state, metadata
  ) values (
    v_organization_id, p_actor_user_id, 'user', p_mission_id,
    'mission_cancellation_requested', 'low', 'cancel_mission', 'allow',
    v_status, 'cancelled',
    jsonb_build_object('mission_id', p_mission_id, 'requested_by', p_actor_user_id)
  );

  return jsonb_build_object(
    'outcome', 'cancelled',
    'mission_id', p_mission_id,
    'status', 'cancelled',
    'previous_status', v_status
  );
end
$fn$;

revoke all on function private.aios_cancel_mission(uuid, uuid) from public, anon, authenticated, service_role;

-- PostgREST-visible wrapper. Only the service-role Edge Function may call it; the private implementation
-- independently verifies the supplied actor's owner/admin membership before changing state.
create or replace function public.aios_cancel_mission(p_mission_id uuid, p_actor_user_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $fn$
  select private.aios_cancel_mission(p_mission_id, p_actor_user_id)
$fn$;

revoke all on function public.aios_cancel_mission(uuid, uuid) from public, anon, authenticated;
grant execute on function public.aios_cancel_mission(uuid, uuid) to service_role;

comment on function public.aios_cancel_mission(uuid, uuid) is
  'Owner/admin cancellation entry point. Terminal missions return already_terminal without changing status, metadata, timestamps, tasks, invocations, or approvals.';
