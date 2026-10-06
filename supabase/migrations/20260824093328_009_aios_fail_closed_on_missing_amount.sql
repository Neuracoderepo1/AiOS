
create or replace function public.aios_enforce_agent_authority()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  agent_authority jsonb;
  agent_limits jsonb;
  agent_risk_rank int;
  invocation_risk_rank int;
  risk_order jsonb := '{"low": 1, "medium": 2, "high": 3}'::jsonb;
  v_key text;
  v_val jsonb;
  v_limit_num numeric;
  v_usd_amount numeric;
  v_concurrent_count numeric;
  v_reason text;
  v_approval_id uuid;
  v_has_usd_limit boolean := false;
  v_has_concurrent_limit boolean := false;
begin
  if new.agent_id is null then
    return new;
  end if;

  select authority into agent_authority from public.aios_agents where id = new.agent_id;
  if agent_authority is null then
    return new;
  end if;

  agent_limits := coalesce(agent_authority->'limits', '{}'::jsonb);
  agent_risk_rank := (risk_order -> (agent_authority->>'risk_level'))::int;
  invocation_risk_rank := (risk_order -> new.risk_level)::int;

  v_usd_amount := nullif(new.arguments->>'usd_amount','')::numeric;
  v_concurrent_count := nullif(new.arguments->>'concurrent_count','')::numeric;

  select bool_or(key like 'max\_%usd' or key = 'max_disbursement' or key like 'requires\_approval\_above%')
    into v_has_usd_limit from jsonb_object_keys(agent_limits) as key;
  select bool_or(key like 'max\_concurrent%')
    into v_has_concurrent_limit from jsonb_object_keys(agent_limits) as key;

  -- Fail closed: if the contract declares a ceiling for a quantity at all, a call
  -- that doesn't report that quantity can't be verified as compliant, so it's held
  -- for a human rather than silently passed. This closes the exact bypass where
  -- omitting `usd_amount` skipped every financial check entirely.
  if v_has_usd_limit and v_usd_amount is null then
    new.status := 'requires_approval';
    v_reason := 'tool call declares no usd_amount, but contract has a USD ceiling — cannot verify compliance';
  end if;

  if new.status is distinct from 'requires_approval' and v_has_concurrent_limit and v_concurrent_count is null then
    new.status := 'requires_approval';
    v_reason := 'tool call declares no concurrent_count, but contract has a concurrency ceiling — cannot verify compliance';
  end if;

  if v_usd_amount is not null then
    for v_key, v_val in select * from jsonb_each(agent_limits) loop
      if v_key like 'max\_%usd' or v_key = 'max_disbursement' then
        v_limit_num := (v_val)::text::numeric;
        if v_usd_amount > v_limit_num then
          new.status := 'denied';
          v_reason := format('%s USD exceeds hard limit %s=%s', v_usd_amount, v_key, v_limit_num);
        end if;
      end if;
    end loop;
  end if;

  if new.status is distinct from 'denied' and v_concurrent_count is not null then
    for v_key, v_val in select * from jsonb_each(agent_limits) loop
      if v_key like 'max\_concurrent%' then
        v_limit_num := (v_val)::text::numeric;
        if v_concurrent_count >= v_limit_num then
          new.status := 'denied';
          v_reason := format('concurrency %s at/over limit %s=%s', v_concurrent_count, v_key, v_limit_num);
        end if;
      end if;
    end loop;
  end if;

  if new.status is distinct from 'denied' then
    if not (agent_authority->'allowed_tools' ? new.tool_name) then
      new.status := 'requires_approval';
      v_reason := format('tool "%s" not in contract', new.tool_name);
    elsif invocation_risk_rank > agent_risk_rank then
      new.status := 'requires_approval';
      v_reason := format('risk "%s" exceeds contracted ceiling "%s"', new.risk_level, agent_authority->>'risk_level');
    end if;
  end if;

  if new.status is distinct from 'denied' and new.status is distinct from 'requires_approval' and v_usd_amount is not null then
    for v_key, v_val in select * from jsonb_each(agent_limits) loop
      if v_key like 'requires\_approval\_above%' then
        v_limit_num := (v_val)::text::numeric;
        if v_usd_amount > v_limit_num then
          new.status := 'requires_approval';
          v_reason := format('%s USD exceeds approval threshold %s=%s', v_usd_amount, v_key, v_limit_num);
        end if;
      end if;
    end loop;
  end if;

  if v_reason is not null then
    new.result := coalesce(new.result,'{}'::jsonb) || jsonb_build_object('kernel_reason', v_reason);
  end if;

  if new.status = 'requires_approval' then
    insert into public.aios_approvals (organization_id, agent_id, task_id, action, risk_level, status)
    values (new.organization_id, new.agent_id, new.task_id, new.tool_name, new.risk_level, 'pending')
    returning id into v_approval_id;
    new.approval_id := v_approval_id;
  end if;

  return new;
end;
$function$;
