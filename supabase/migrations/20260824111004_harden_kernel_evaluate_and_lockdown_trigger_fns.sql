
-- 1. aios_risk_rank: pin search_path (advisor flagged this as mutable)
create or replace function public.aios_risk_rank(p text)
returns integer
language sql
immutable
set search_path = 'public'
as $function$
  select case lower(coalesce(p,'low')) when 'high' then 3 when 'medium' then 2 else 1 end;
$function$;

-- 2. aios_kernel_evaluate: currently has NO auth/membership check at all, and is
-- directly callable by the anon role (the key shipped in the public landing page).
-- Anyone could fabricate aios_tool_invocations rows — and trigger real
-- aios_approvals rows — against any organization's agents. Add the same
-- membership guard aios_public_metrics already uses, and revoke anon execute
-- (org membership requires an authenticated session, so anon could never pass
-- the check anyway — revoking removes the dead attack surface / confusing 403s).
create or replace function public.aios_kernel_evaluate(
  p_agent_id uuid,
  p_task_id uuid,
  p_tool_name text,
  p_risk_level text default 'low'::text,
  p_usd_amount numeric default null::numeric,
  p_concurrent_count integer default null::integer,
  p_arguments jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  v_org_id uuid;
  v_row record;
  v_merged_args jsonb;
begin
  select organization_id into v_org_id from aios_agents where id = p_agent_id;
  if v_org_id is null then
    raise exception 'unknown agent_id %', p_agent_id;
  end if;

  if not public.aios_is_org_member(v_org_id) then
    raise exception 'not a member of this organization' using errcode = '42501';
  end if;

  v_merged_args := p_arguments
    || case when p_usd_amount is not null then jsonb_build_object('usd_amount', p_usd_amount) else '{}'::jsonb end
    || case when p_concurrent_count is not null then jsonb_build_object('concurrent_count', p_concurrent_count) else '{}'::jsonb end;

  insert into aios_tool_invocations (organization_id, agent_id, task_id, tool_name, arguments, status, risk_level)
  values (v_org_id, p_agent_id, p_task_id, p_tool_name, v_merged_args, 'requested', p_risk_level)
  returning * into v_row;

  if v_row.status = 'requested' then
    update aios_tool_invocations set status='completed', completed_at=now() where id = v_row.id returning * into v_row;
  end if;

  return jsonb_build_object(
    'decision', case v_row.status when 'denied' then 'deny' when 'requires_approval' then 'approval' else 'allow' end,
    'reason', coalesce(v_row.result->>'kernel_reason','within contract'),
    'tool_invocation_id', v_row.id,
    'approval_id', v_row.approval_id
  );
end;
$function$;

revoke execute on function public.aios_kernel_evaluate(uuid, uuid, text, text, numeric, integer, jsonb) from anon;

-- 3. aios_handle_new_user: trigger-only function (fires on auth.users insert).
-- Trigger execution doesn't require EXECUTE privilege, so it's safe to revoke
-- direct RPC callability from anon/authenticated/public — closes the
-- "Public Can Execute SECURITY DEFINER Function" advisor flag with no
-- functional impact on signup.
revoke execute on function public.aios_handle_new_user() from public, anon, authenticated;
