
-- Superseded by the fixed aios_enforce_agent_authority trigger, which is the single
-- source of truth now. This becomes a thin convenience wrapper for callers (RPC from
-- app code) instead of a second, independently-reasoning kernel.
create or replace function public.aios_kernel_evaluate(
  p_agent_id uuid,
  p_task_id uuid,
  p_tool_name text,
  p_risk_level text default 'low',
  p_usd_amount numeric default null,
  p_concurrent_count int default null,
  p_arguments jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_row record;
  v_merged_args jsonb;
begin
  select organization_id into v_org_id from aios_agents where id = p_agent_id;
  if v_org_id is null then
    raise exception 'unknown agent_id %', p_agent_id;
  end if;

  v_merged_args := p_arguments
    || case when p_usd_amount is not null then jsonb_build_object('usd_amount', p_usd_amount) else '{}'::jsonb end
    || case when p_concurrent_count is not null then jsonb_build_object('concurrent_count', p_concurrent_count) else '{}'::jsonb end;

  insert into aios_tool_invocations (organization_id, agent_id, task_id, tool_name, arguments, status, risk_level)
  values (v_org_id, p_agent_id, p_task_id, p_tool_name, v_merged_args, 'requested', p_risk_level)
  returning * into v_row;
  -- v_row now reflects whatever aios_enforce_agent_authority decided (denied /
  -- requires_approval / requested), since that trigger runs BEFORE this insert commits.

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
$$;
