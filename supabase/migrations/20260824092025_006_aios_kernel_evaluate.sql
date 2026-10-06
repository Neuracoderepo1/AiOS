
create or replace function public.aios_risk_rank(p text)
returns int language sql immutable as $$
  select case lower(coalesce(p,'low')) when 'high' then 3 when 'medium' then 2 else 1 end;
$$;

-- The kernel: every tool request an agent makes should be evaluated here before
-- it executes. Returns ALLOW / DENY / APPROVAL plus the reason, and — unlike the
-- rest of this schema — writes its own audit trail atomically with the decision,
-- so a decision and its record can never drift apart.
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
  v_contract record;
  v_decision text := 'allow';
  v_reason text := 'within contract';
  v_key text;
  v_val jsonb;
  v_limit_num numeric;
  v_inv_id uuid;
  v_appr_id uuid;
begin
  select organization_id into v_org_id from aios_agents where id = p_agent_id;
  if v_org_id is null then
    raise exception 'unknown agent_id %', p_agent_id;
  end if;

  select * into v_contract from aios_contracts where agent_id = p_agent_id and is_active limit 1;
  if not found then
    raise exception 'agent % has no active contract', p_agent_id;
  end if;

  -- 1. Tool must be on the whitelist. Not being there isn't a silent no-op —
  --    it's routed to a human, same as any other request the contract doesn't cover.
  if not (v_contract.allowed_tools ? p_tool_name) then
    v_decision := 'approval'; v_reason := format('tool "%s" not in contract (allowed: %s)', p_tool_name, v_contract.allowed_tools::text);
  end if;

  -- 2. Risk ceiling. A request riskier than the agent's contracted ceiling needs sign-off.
  if v_decision = 'allow' and aios_risk_rank(p_risk_level) > aios_risk_rank(v_contract.risk_level) then
    v_decision := 'approval'; v_reason := format('risk "%s" exceeds contracted ceiling "%s"', p_risk_level, v_contract.risk_level);
  end if;

  -- 3. Hard ceilings: any limit key prefixed max_* compared against a USD amount context.
  --    Limits are free-form by design, so we match by convention rather than a fixed column,
  --    but a breach here is a DENY, never just an approval — the contract says never, full stop.
  if v_decision = 'allow' and p_usd_amount is not null then
    for v_key, v_val in select * from jsonb_each(v_contract.limits)
    loop
      if v_key like 'max\_%usd' or v_key = 'max_disbursement' then
        v_limit_num := (v_val)::text::numeric;
        if p_usd_amount > v_limit_num then
          v_decision := 'deny'; v_reason := format('%s USD exceeds hard limit %s=%s', p_usd_amount, v_key, v_limit_num);
        end if;
      end if;
    end loop;
  end if;

  -- 4. Soft threshold: requires_approval_above_* — allowed, but only with sign-off.
  if v_decision = 'allow' and p_usd_amount is not null then
    for v_key, v_val in select * from jsonb_each(v_contract.limits)
    loop
      if v_key like 'requires\_approval\_above%' then
        v_limit_num := (v_val)::text::numeric;
        if p_usd_amount > v_limit_num then
          v_decision := 'approval'; v_reason := format('%s USD exceeds approval threshold %s=%s', p_usd_amount, v_key, v_limit_num);
        end if;
      end if;
    end loop;
  end if;

  -- 5. Concurrency ceilings: max_concurrent_* — structural capacity, hard deny at/over limit.
  if v_decision = 'allow' and p_concurrent_count is not null then
    for v_key, v_val in select * from jsonb_each(v_contract.limits)
    loop
      if v_key like 'max\_concurrent%' then
        v_limit_num := (v_val)::text::numeric;
        if p_concurrent_count >= v_limit_num then
          v_decision := 'deny'; v_reason := format('concurrency %s at/over limit %s=%s', p_concurrent_count, v_key, v_limit_num);
        end if;
      end if;
    end loop;
  end if;

  insert into aios_tool_invocations (organization_id, agent_id, task_id, tool_name, arguments, status, risk_level, completed_at)
  values (
    v_org_id, p_agent_id, p_task_id, p_tool_name, p_arguments,
    case v_decision when 'allow' then 'completed' when 'deny' then 'denied' else 'pending_approval' end,
    p_risk_level,
    case when v_decision = 'allow' then now() else null end
  ) returning id into v_inv_id;

  if v_decision = 'approval' then
    insert into aios_approvals (organization_id, agent_id, task_id, action, risk_level, status)
    values (v_org_id, p_agent_id, p_task_id, p_tool_name, p_risk_level, 'pending')
    returning id into v_appr_id;
    update aios_tool_invocations set approval_id = v_appr_id where id = v_inv_id;
  end if;

  insert into aios_audit_events (organization_id, agent_id, task_id, event_type, risk_level, action, decision, metadata)
  values (
    v_org_id, p_agent_id, p_task_id,
    format('Kernel %s: %s', upper(v_decision), p_tool_name),
    p_risk_level, p_tool_name, v_decision,
    jsonb_build_object('reason', v_reason, 'contract_version', v_contract.version, 'tool_invocation_id', v_inv_id, 'approval_id', v_appr_id)
  );

  return jsonb_build_object('decision', v_decision, 'reason', v_reason, 'tool_invocation_id', v_inv_id, 'approval_id', v_appr_id, 'contract_version', v_contract.version);
end;
$$;
