-- Fix: approval-gated invocations could not be created or executed.
-- (1) The approval row was inserted from the BEFORE INSERT trigger referencing new.id before the
--     invocation row existed, so aios_validate_approval_integrity rejected it (23514). The approval is now
--     inserted unbound; the existing AFTER INSERT trigger aios_bind_invocation_approval binds it
--     (invocation_id, tool_key, arguments_hash, approval_version).
-- (2) authorization_version was left NULL on the requires_approval path, so
--     aios_kernel_authorize_invocation always denied it as stale. It is now set to the contract version.
CREATE OR REPLACE FUNCTION private.aios_enforce_agent_authority()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_agent record;
  v_contract record;
  v_tool record;
  v_reason text;
  v_approval uuid;
  v_limits jsonb;
  v_usd_amount numeric;
  v_concurrent_count numeric;
  v_key text;
  v_val jsonb;
  v_limit_num numeric;
  v_has_usd_limit boolean := false;
  v_has_concurrent_limit boolean := false;
  v_prior_approval_id uuid;
  v_hard_denied boolean := false;
begin
  select a.id, a.organization_id, a.status into v_agent
  from public.aios_agents a where a.id = new.agent_id;

  if v_agent.id is null then
    raise exception 'agent not found';
  end if;
  if v_agent.organization_id is distinct from new.organization_id then
    raise exception 'agent organization mismatch';
  end if;

  new.arguments := coalesce(new.arguments, '{}'::jsonb);
  new.arguments_hash := encode(extensions.digest(new.arguments::text,'sha256'),'hex');

  if v_agent.status = 'suspended' then
    new.status := 'denied';
    new.result := jsonb_build_object('kernel_reason','agent suspended');
    return new;
  end if;

  select c.id, c.version, c.risk_level, c.allowed_tools, c.limits into v_contract
  from public.aios_contracts c
  where c.agent_id = new.agent_id and c.organization_id = new.organization_id and c.is_active
  order by c.version desc limit 1;

  if v_contract.id is null then
    new.status := 'denied';
    new.result := jsonb_build_object('kernel_reason','no active contract');
    return new;
  end if;

  select t.id, t.tool_key, t.risk_level, t.is_enabled, t.status, t.requires_approval
  into v_tool
  from public.aios_tools t
  where t.tool_key = coalesce(new.tool_key, new.tool_name);

  if v_tool.id is null then
    new.status := 'denied';
    new.result := jsonb_build_object('kernel_reason','unknown tool');
    return new;
  end if;

  if not v_tool.is_enabled or v_tool.status <> 'active' then
    new.status := 'denied';
    new.result := jsonb_build_object('kernel_reason','tool disabled');
    return new;
  end if;

  new.tool_key := v_tool.tool_key;
  new.tool_name := v_tool.tool_key;
  -- arguments/arguments_hash already normalized above, before any early return

  v_limits := coalesce(v_contract.limits, '{}'::jsonb);
  v_usd_amount := nullif(new.arguments->>'usd_amount','')::numeric;
  v_concurrent_count := nullif(new.arguments->>'concurrent_count','')::numeric;

  if new.task_id is not null then
    select id into v_prior_approval_id
    from public.aios_approvals
    where organization_id = new.organization_id
      and agent_id = new.agent_id
      and task_id = new.task_id
      and tool_key = v_tool.tool_key
      and status = 'approved'
      and (expires_at is null or expires_at > now())
    order by reviewed_at desc nulls last, created_at desc
    limit 1;
  end if;

  select bool_or(key like 'max\_%usd' or key = 'max_disbursement' or key like 'requires\_approval\_above%')
    into v_has_usd_limit from jsonb_object_keys(v_limits) as key;
  select bool_or(key like 'max\_concurrent%')
    into v_has_concurrent_limit from jsonb_object_keys(v_limits) as key;

  if not (v_contract.allowed_tools ? v_tool.tool_key) then
    v_reason := 'tool not in active contract';
  elsif public.aios_risk_rank(v_tool.risk_level) > public.aios_risk_rank(v_contract.risk_level)
     or public.aios_risk_rank(new.risk_level) > public.aios_risk_rank(v_contract.risk_level) then
    v_reason := 'risk exceeds contract ceiling';
  elsif v_tool.requires_approval then
    v_reason := 'tool requires approval';
  end if;

  if v_reason is null and v_has_usd_limit and v_usd_amount is null then
    v_reason := 'tool call declares no usd_amount, but contract has a USD ceiling — cannot verify compliance';
  end if;
  if v_reason is null and v_has_concurrent_limit and v_concurrent_count is null then
    v_reason := 'tool call declares no concurrent_count, but contract has a concurrency ceiling — cannot verify compliance';
  end if;

  -- Hard limits: terminal, never bypassed by prior approval.
  if v_usd_amount is not null then
    for v_key, v_val in select * from jsonb_each(v_limits) loop
      if v_key like 'max\_%usd' or v_key = 'max_disbursement' then
        v_limit_num := (v_val)::text::numeric;
        if v_usd_amount > v_limit_num then
          v_hard_denied := true;
          v_reason := format('%s USD exceeds hard limit %s=%s', v_usd_amount, v_key, v_limit_num);
        end if;
      end if;
    end loop;
  end if;

  if not v_hard_denied and v_concurrent_count is not null then
    for v_key, v_val in select * from jsonb_each(v_limits) loop
      if v_key like 'max\_concurrent%' then
        v_limit_num := (v_val)::text::numeric;
        if v_concurrent_count >= v_limit_num then
          v_hard_denied := true;
          v_reason := format('concurrency %s at/over limit %s=%s', v_concurrent_count, v_key, v_limit_num);
        end if;
      end if;
    end loop;
  end if;

  if v_hard_denied then
    new.status := 'denied';
    new.result := jsonb_build_object('kernel_reason', v_reason, 'contract_version', v_contract.version);
    return new;
  end if;

  if v_reason is null and v_usd_amount is not null then
    for v_key, v_val in select * from jsonb_each(v_limits) loop
      if v_key like 'requires\_approval\_above%' then
        v_limit_num := (v_val)::text::numeric;
        if v_usd_amount > v_limit_num then
          v_reason := format('%s USD exceeds approval threshold %s=%s', v_usd_amount, v_key, v_limit_num);
        end if;
      end if;
    end loop;
  end if;

  if v_reason is not null then
    if v_prior_approval_id is not null then
      new.authorization_version := v_contract.version;
      new.status := 'approved';
      new.approval_id := v_prior_approval_id;
      new.result := jsonb_build_object('kernel_reason', format('cleared by prior human approval %s', v_prior_approval_id), 'contract_version', v_contract.version);
    else
      new.status := 'requires_approval';
      new.authorization_version := v_contract.version;
      new.result := jsonb_build_object('kernel_reason', v_reason, 'contract_version', v_contract.version);
      -- invocation_id is bound by trg_aios_bind_invocation_approval (AFTER INSERT), once the row exists
      insert into public.aios_approvals(
        organization_id, agent_id, task_id, invocation_id, action, risk_level, resource, reason,
        approval_reason, tool_key, arguments_hash, approval_version, status, expires_at
      ) values (
        new.organization_id, new.agent_id, new.task_id, null, new.tool_key, new.risk_level, new.tool_key,
        v_reason, v_reason, v_tool.tool_key, new.arguments_hash, v_contract.version, 'pending', now() + interval '30 minutes'
      ) returning id into v_approval;
      new.approval_id := v_approval;
    end if;
  else
    new.authorization_version := v_contract.version;
    new.status := 'approved';
  end if;

  return new;
end;
$function$;
