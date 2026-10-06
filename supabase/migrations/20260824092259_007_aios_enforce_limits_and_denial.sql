
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
begin
  if new.agent_id is null then
    return new; -- no agent assigned yet, nothing to check
  end if;

  select authority into agent_authority
  from public.aios_agents
  where id = new.agent_id;

  if agent_authority is null then
    return new; -- agent not found; FK constraint already guards this
  end if;

  agent_limits := coalesce(agent_authority->'limits', '{}'::jsonb);
  agent_risk_rank := (risk_order -> (agent_authority->>'risk_level'))::int;
  invocation_risk_rank := (risk_order -> new.risk_level)::int;

  -- Free-form quantities a caller can pass in `arguments` for the limits below
  -- to actually mean something: {"usd_amount": 6000, "concurrent_count": 1}.
  v_usd_amount := nullif(new.arguments->>'usd_amount','')::numeric;
  v_concurrent_count := nullif(new.arguments->>'concurrent_count','')::numeric;

  -- 1. Hard ceilings first — a breach here is DENIED, never just held for approval.
  --    This is the check that was previously entirely missing: `limits` existed as
  --    data but nothing ever compared a real request against it.
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

  -- 2. Existing checks (unchanged behavior): whitelist + risk ceiling -> held for approval.
  if new.status is distinct from 'denied' then
    if not (agent_authority->'allowed_tools' ? new.tool_name) then
      new.status := 'requires_approval';
      v_reason := format('tool "%s" not in contract', new.tool_name);
    elsif invocation_risk_rank > agent_risk_rank then
      new.status := 'requires_approval';
      v_reason := format('risk "%s" exceeds contracted ceiling "%s"', new.risk_level, agent_authority->>'risk_level');
    end if;
  end if;

  -- 3. New: soft USD threshold -> held for approval (previously not checked at all).
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

  -- Stash the reason where the audit trigger (AFTER INSERT) can read it, and where a
  -- human reviewing this row later can see why the kernel decided what it decided.
  if v_reason is not null then
    new.result := coalesce(new.result,'{}'::jsonb) || jsonb_build_object('kernel_reason', v_reason);
  end if;

  -- Previously nothing created the approval row a "requires_approval" status implies —
  -- it silently relied on some other caller remembering to do it. Do it here so the
  -- state machine can't skip this step.
  if new.status = 'requires_approval' then
    insert into public.aios_approvals (organization_id, agent_id, task_id, action, risk_level, status)
    values (new.organization_id, new.agent_id, new.task_id, new.tool_name, new.risk_level, 'pending')
    returning id into v_approval_id;
    new.approval_id := v_approval_id;
  end if;

  return new;
end;
$function$;

create or replace function public.aios_log_tool_invocation_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_approval record;
begin
  if tg_op = 'INSERT' then
    insert into public.aios_audit_events(
      organization_id, agent_id, task_id, event_type, risk_level, action, decision, metadata
    ) values (
      new.organization_id, new.agent_id, new.task_id,
      'tool_invocation_requested', new.risk_level, new.tool_name,
      case new.status
        when 'denied' then 'denied'
        when 'requires_approval' then 'held_for_approval'
        else 'auto_approved'
      end,
      jsonb_build_object(
        'invocation_id', new.id,
        'arguments', new.arguments,
        'approval_id', new.approval_id,
        'reason', new.result->>'kernel_reason'
      )
    );
    return new;
  end if;

  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status in ('approved', 'rejected') then
      select reviewed_by, reason into v_approval from public.aios_approvals where id = new.approval_id;
      insert into public.aios_audit_events(
        organization_id, agent_id, task_id, event_type, risk_level, action, decision, metadata
      ) values (
        new.organization_id, new.agent_id, new.task_id,
        'tool_invocation_reviewed', new.risk_level, new.tool_name, new.status,
        jsonb_build_object(
          'invocation_id', new.id,
          'approval_id', new.approval_id,
          'reviewed_by', v_approval.reviewed_by,
          'reason', v_approval.reason
        )
      );
    else
      insert into public.aios_audit_events(
        organization_id, agent_id, task_id, event_type, risk_level, action, decision, metadata
      ) values (
        new.organization_id, new.agent_id, new.task_id,
        'tool_invocation_status_changed', new.risk_level, new.tool_name, new.status,
        jsonb_build_object('invocation_id', new.id, 'previous_status', old.status)
      );
    end if;
  end if;

  return new;
end;
$function$;
