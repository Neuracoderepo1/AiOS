-- AiOS final kernel hardening: CURRENT AUTHORITY > HISTORICAL APPROVAL.
-- Scope: closes only the gaps listed in the hardening brief. No architecture change, no new product features.
--
--  1. Agent revocation        -> final authorizer re-checks the CURRENT agent status.
--  2. Contract ceiling        -> final authorizer re-checks the CURRENT active contract.
--  3. Tool risk revocation    -> CURRENT registry risk is compared with the CURRENT contract ceiling at execution.
--  4. Self-approval           -> enforced in the database (trigger + CHECK), reachable by no caller.
--  5. Approval forgery        -> an approval cannot become approved without a valid reviewer and passing integrity checks.
--  6. Risk source of truth    -> invocation.risk_level is overwritten with the registry risk and is immutable.
--  7. Approval binding        -> approval is bound to org/agent/task/tool/risk/args-hash/contract-version/requester/reviewer/expiry.
--  8. Final re-authorization  -> one canonical check immediately before the trusted executor runs; 'executing' is claimed once.
--  +  Reachability            -> service_role could not resolve schema private (permission denied), so the canonical
--                                RPCs the Edge Functions call were unreachable on the real PostgREST path.

-- ------------------------------------------------------------------ reachability
-- service_role already holds EXECUTE on the specific private kernel functions; only schema USAGE was missing.
grant usage on schema private to service_role;

-- ------------------------------------------------------------------ shared helper (single source of truth)
-- Agent statuses are free-form UI labels on live (Idle, Working, Coordinating, Designing, idle ...), so an allow-list
-- would lock out real agents. Revocation is therefore an explicit deny-list evaluated in ONE place.
create or replace function private.aios_agent_authorized(p_status text)
 returns boolean
 language sql
 immutable
 set search_path to ''
as $function$
  select lower(btrim(coalesce(p_status, ''))) not in
    ('suspended','revoked','inactive','disabled','deactivated','terminated','retired','archived','banned','blocked','deleted');
$function$;
revoke all on function private.aios_agent_authorized(text) from public, anon, authenticated;

-- ------------------------------------------------------------------ approvals: requester identity + DB-level invariant
alter table public.aios_approvals add column if not exists requester_id uuid;

-- Backfill is metadata-only; the integrity trigger is paused for this single statement (same transaction) so a legacy
-- row with an old, inconsistent binding cannot abort the migration. It is re-enabled immediately afterwards.
alter table public.aios_approvals disable trigger trg_aios_validate_approval_integrity;
update public.aios_approvals a
   set requester_id = i.requested_by
  from public.aios_tool_invocations i
 where i.id = a.invocation_id
   and a.requester_id is null;
alter table public.aios_approvals enable trigger trg_aios_validate_approval_integrity;

create or replace function private.aios_validate_approval_integrity()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  ag public.aios_agents;
  tk public.aios_tasks;
  inv public.aios_tool_invocations;
  v_reg_risk text;
begin
  if tg_op = 'INSERT' and new.status is distinct from 'pending' then
    raise exception 'approvals must be created pending and resolved through the canonical resolver' using errcode = '23514';
  end if;

  -- A resolved approval is a sealed record: its binding, identities and expiry can never be edited afterwards
  -- (otherwise an expired approval could be revived or its reviewer rewritten by direct SQL).
  if tg_op = 'UPDATE' and old.status in ('approved','rejected','expired') then
    if (new.organization_id, new.agent_id, new.task_id, new.invocation_id, new.tool_key, new.arguments_hash, new.approval_version,
        new.risk_level, new.expires_at, new.reviewed_by, new.approved_by, new.reviewed_at, new.approved_at, new.requester_id)
       is distinct from
       (old.organization_id, old.agent_id, old.task_id, old.invocation_id, old.tool_key, old.arguments_hash, old.approval_version,
        old.risk_level, old.expires_at, old.reviewed_by, old.approved_by, old.reviewed_at, old.approved_at, old.requester_id) then
      raise exception 'resolved approval is immutable' using errcode = '42501';
    end if;
  end if;

  if new.invocation_id is not null then
    select * into inv from public.aios_tool_invocations where id = new.invocation_id;
    if inv.id is null or inv.organization_id <> new.organization_id then raise exception 'approval invocation organization mismatch' using errcode = '23514'; end if;
    if new.agent_id is not null and inv.agent_id is distinct from new.agent_id then raise exception 'approval agent mismatch' using errcode = '23514'; end if;
    if new.task_id is not null and inv.task_id is distinct from new.task_id then raise exception 'approval task mismatch' using errcode = '23514'; end if;
    if new.tool_key is not null and new.tool_key is distinct from inv.tool_key then raise exception 'approval tool mismatch' using errcode = '23514'; end if;
    if new.arguments_hash is not null and new.arguments_hash is distinct from inv.arguments_hash then raise exception 'approval argument hash mismatch' using errcode = '23514'; end if;
    if new.approval_version is not null and inv.authorization_version is not null and new.approval_version is distinct from inv.authorization_version then raise exception 'approval authorization version mismatch' using errcode = '23514'; end if;
    -- the requester is always derived from the invocation; it can never be supplied or forged by the writer
    new.requester_id := inv.requested_by;
  end if;

  if new.agent_id is not null then
    select * into ag from public.aios_agents where id = new.agent_id;
    if ag.id is null or ag.organization_id <> new.organization_id then raise exception 'approval agent organization mismatch' using errcode = '23514'; end if;
  end if;
  if new.task_id is not null then
    select * into tk from public.aios_tasks where id = new.task_id;
    if tk.id is null or tk.organization_id <> new.organization_id then raise exception 'approval task organization mismatch' using errcode = '23514'; end if;
  end if;

  if new.status = 'approved' then
    if new.invocation_id is null or new.tool_key is null or new.arguments_hash is null or new.approval_version is null then
      raise exception 'approved approval must be fully bound to invocation authorization context' using errcode = '23514';
    end if;
    -- identity / authority checks run on every transition into 'approved' (resolver, direct SQL, service role alike)
    if tg_op = 'INSERT' or old.status is distinct from 'approved' then
      if new.reviewed_by is null or new.approved_by is distinct from new.reviewed_by then
        raise exception 'approval requires a valid reviewer identity' using errcode = '42501';
      end if;
      if new.requester_id is null then
        raise exception 'approval requester identity is missing' using errcode = '42501';
      end if;
      if new.reviewed_by = new.requester_id then
        raise exception 'self-approval is not permitted: requester and reviewer must differ' using errcode = '42501';
      end if;
      if not exists (select 1 from public.aios_organization_members om
                      where om.organization_id = new.organization_id and om.user_id = new.reviewed_by and om.role in ('owner','admin')) then
        raise exception 'reviewer is not an organization owner/admin' using errcode = '42501';
      end if;
      if new.expires_at is null or new.expires_at <= now() then
        raise exception 'approval has no valid expiry' using errcode = '23514';
      end if;
      select t.risk_level into v_reg_risk from public.aios_tools t where t.tool_key = new.tool_key;
      if v_reg_risk is null or new.risk_level is distinct from v_reg_risk then
        raise exception 'approval risk does not match canonical registry risk' using errcode = '23514';
      end if;
      if inv.status is distinct from 'requires_approval' then
        raise exception 'invocation is not awaiting approval' using errcode = '40001';
      end if;
    end if;
  end if;
  return new;
end $function$;

-- Belt and braces: the same invariant as a table constraint. NOT VALID so it enforces every new/updated row without
-- rewriting history (1 legacy approved row on live predates the rule and is left untouched; it can never authorize
-- execution because the final authorizer re-validates identity).
alter table public.aios_approvals drop constraint if exists aios_approvals_reviewer_integrity;
alter table public.aios_approvals add constraint aios_approvals_reviewer_integrity
  check (status <> 'approved'
         or (requester_id is not null and reviewed_by is not null
             and approved_by is not distinct from reviewed_by and requester_id <> reviewed_by)) not valid;

-- ------------------------------------------------------------------ risk level: canonical registry value, immutable
create or replace function private.aios_validate_invocation_registry()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare t public.aios_tools; v_hash text;
begin
  if tg_op = 'UPDATE' then
    if new.organization_id is distinct from old.organization_id or new.agent_id is distinct from old.agent_id or new.task_id is distinct from old.task_id
       or new.tool_key is distinct from old.tool_key or new.tool_name is distinct from old.tool_name
       or new.authorization_version is distinct from old.authorization_version or new.approval_id is distinct from old.approval_id
       or new.arguments is distinct from old.arguments then
      if old.status not in ('requested','evaluating') then
        raise exception 'invocation authorization context is immutable after evaluation begins' using errcode = '40001';
      end if;
    end if;
  end if;
  select * into t from public.aios_tools where tool_key = coalesce(new.tool_key, new.tool_name);
  if t.id is null then raise exception 'tool is not registered' using errcode = '22023'; end if;
  if not t.is_enabled or t.status <> 'active' then raise exception 'tool is disabled or inactive' using errcode = '42501'; end if;
  if new.tool_key is distinct from t.tool_key or new.tool_name is distinct from t.tool_key then
    raise exception 'tool identity does not match canonical registry' using errcode = '22023';
  end if;
  -- the caller's risk label is untrusted: the stored value is always the canonical registry risk and never changes
  if tg_op = 'INSERT' then
    new.risk_level := t.risk_level;
  elsif new.risk_level is distinct from old.risk_level then
    raise exception 'invocation risk_level is canonical and immutable' using errcode = '40001';
  end if;
  if not extensions.jsonb_matches_schema(t.input_schema::json, new.arguments) then
    raise exception 'tool arguments do not match registry input schema' using errcode = '22023';
  end if;
  v_hash = encode(extensions.digest(convert_to(new.arguments::text, 'UTF8'), 'sha256'), 'hex');
  if tg_op = 'INSERT' or (new.arguments is distinct from old.arguments and old.status in ('requested','evaluating')) then
    new.arguments_hash = v_hash;
  end if;
  if tg_op = 'UPDATE' and old.status in ('approved','executing') and new.approval_id is null and t.requires_approval then
    raise exception 'approval binding cannot be removed from approved execution' using errcode = '42501';
  end if;
  return new;
end $function$;

drop trigger if exists trg_aios_validate_invocation_registry on public.aios_tool_invocations;
create trigger trg_aios_validate_invocation_registry
  before insert or update of tool_key, tool_name, arguments, risk_level on public.aios_tool_invocations
  for each row execute function private.aios_validate_invocation_registry();

-- ------------------------------------------------------------------ insert-time kernel: canonical risk + shared revocation list
create or replace function private.aios_enforce_agent_authority()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
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
  v_canon_risk text;
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

  -- the caller-supplied risk label is untrusted input: resolve the canonical registry risk first
  select t0.risk_level into v_canon_risk from public.aios_tools t0 where t0.tool_key = coalesce(new.tool_key, new.tool_name);
  if v_canon_risk is not null then
    new.risk_level := v_canon_risk;
  end if;

  if not private.aios_agent_authorized(v_agent.status) then
    new.status := 'denied';
    new.result := jsonb_build_object('kernel_reason', format('agent not authorized (status: %s)', v_agent.status));
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
  elsif public.aios_risk_rank(v_tool.risk_level) > public.aios_risk_rank(v_contract.risk_level) then
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

-- ------------------------------------------------------------------ the final canonical authorization gate
-- UNTRUSTED REQUEST -> CURRENT AGENT -> CURRENT CONTRACT -> CURRENT TOOL REGISTRY -> CURRENT RISK -> CURRENT LIMITS
-- -> APPROVAL VALIDITY -> FINAL KERNEL DECISION -> EXECUTE OR DENY. No stored status is permanent authority.
create or replace function private.aios_kernel_authorize_invocation(p_invocation_id uuid)
 returns public.aios_tool_invocations
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v public.aios_tool_invocations;
  ag public.aios_agents;
  c public.aios_contracts;
  a public.aios_approvals;
  t public.aios_tools;
  ex text;
  v_hash text;
  v_needs boolean := false;
  v_usd numeric;
  v_cc numeric;
  v_key text;
  v_val jsonb;
  v_lim numeric;
  v_has_usd boolean := false;
  v_has_cc boolean := false;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'service-role execution context required' using errcode = '42501';
  end if;

  select * into v from public.aios_tool_invocations where id = p_invocation_id for update;
  if v.id is null then raise exception 'invocation not found' using errcode = 'P0002'; end if;

  -- 1. CURRENT AGENT
  select * into ag from public.aios_agents where id = v.agent_id and organization_id = v.organization_id;
  if ag.id is null then raise exception 'agent not found in invocation organization' using errcode = '42501'; end if;
  if not private.aios_agent_authorized(ag.status) then
    raise exception 'agent is not authorized to execute (status: %)', ag.status using errcode = '42501';
  end if;

  -- 2. CURRENT CONTRACT
  select * into c from public.aios_contracts
   where agent_id = v.agent_id and organization_id = v.organization_id and is_active order by version desc limit 1;
  if c.id is null then raise exception 'no active contract' using errcode = '42501'; end if;
  if not (v.tool_key = any(array(select jsonb_array_elements_text(c.allowed_tools)))) then
    raise exception 'tool is not authorized by active contract' using errcode = '42501';
  end if;

  -- 3. CURRENT TOOL REGISTRY
  select * into t from public.aios_tools where tool_key = v.tool_key;
  if t.id is null or not t.is_enabled or t.status <> 'active' then raise exception 'tool unavailable' using errcode = '42501'; end if;
  ex := private.aios_validate_executor_registry(v.tool_key);
  if ex is null then raise exception 'missing trusted executor' using errcode = '42501'; end if;
  if t.handler is null or t.handler = '' then raise exception 'invalid registry configuration: missing handler' using errcode = '42501'; end if;

  -- 4. CURRENT RISK: registry risk vs current contract ceiling (the caller's label is never consulted)
  if public.aios_risk_rank(t.risk_level) > public.aios_risk_rank(c.risk_level) then
    raise exception 'tool registry risk (%) exceeds current contract ceiling (%)', t.risk_level, c.risk_level using errcode = '42501';
  end if;

  if not extensions.jsonb_matches_schema(t.input_schema::json, v.arguments) then
    raise exception 'invocation arguments fail registry schema' using errcode = '22023';
  end if;
  v_hash := encode(extensions.digest(convert_to(v.arguments::text, 'UTF8'), 'sha256'), 'hex');
  if v.arguments_hash is distinct from v_hash then raise exception 'invocation argument hash mismatch' using errcode = '42501'; end if;
  if v.authorization_version is distinct from c.version then raise exception 'authorization version is stale' using errcode = '40901'; end if;

  -- 5. CURRENT LIMITS (re-evaluated against the current contract, not the contract at request time)
  v_usd := nullif(v.arguments->>'usd_amount','')::numeric;
  v_cc  := nullif(v.arguments->>'concurrent_count','')::numeric;
  for v_key, v_val in select * from jsonb_each(coalesce(c.limits, '{}'::jsonb)) loop
    if v_key like 'max\_%usd' or v_key = 'max_disbursement' then
      v_has_usd := true; v_lim := (v_val)::text::numeric;
      if v_usd is not null and v_usd > v_lim then
        raise exception '% USD exceeds current hard limit %=%', v_usd, v_key, v_lim using errcode = '42501';
      end if;
    elsif v_key like 'requires\_approval\_above%' then
      v_has_usd := true; v_lim := (v_val)::text::numeric;
      if v_usd is not null and v_usd > v_lim then v_needs := true; end if;
    elsif v_key like 'max\_concurrent%' then
      v_has_cc := true; v_lim := (v_val)::text::numeric;
      if v_cc is not null and v_cc >= v_lim then
        raise exception 'concurrency % at/over current limit %=%', v_cc, v_key, v_lim using errcode = '42501';
      end if;
    end if;
  end loop;
  if (v_has_usd and v_usd is null) or (v_has_cc and v_cc is null) then v_needs := true; end if;

  -- 6. APPROVAL VALIDITY: required whenever the CURRENT authority says so, never merely because one once existed
  v_needs := v_needs or v.status = 'requires_approval' or t.requires_approval
             or coalesce((c.limits->>'requires_approval')::boolean, false);
  if v_needs then
    select * into a from public.aios_approvals where id = v.approval_id and invocation_id = v.id for update;
    if a.id is null or a.status <> 'approved' or a.expires_at is null or a.expires_at <= now() then
      raise exception 'valid approval required' using errcode = '42501';
    end if;
    if a.organization_id is distinct from v.organization_id
       or a.agent_id is distinct from v.agent_id
       or a.task_id is distinct from v.task_id
       or a.tool_key is distinct from v.tool_key
       or a.arguments_hash is distinct from v_hash
       or a.approval_version is distinct from c.version
       or a.risk_level is distinct from t.risk_level then
      raise exception 'approval no longer matches invocation authorization context' using errcode = '42501';
    end if;
    if v.requested_by is null or a.reviewed_by is null or a.approved_by is distinct from a.reviewed_by or a.reviewed_by = v.requested_by then
      raise exception 'approval identity is invalid (requester and reviewer must be distinct, present identities)' using errcode = '42501';
    end if;
  end if;

  -- 7. FINAL KERNEL DECISION: claim execution exactly once
  if v.status = 'executing' then
    raise exception 'invocation already claimed for execution' using errcode = '40001';
  end if;
  if v.status not in ('approved','requires_approval') then
    raise exception 'invocation is not executable: %', v.status using errcode = '40001';
  end if;
  if v.status = 'requires_approval' then
    update public.aios_tool_invocations set status = 'approved' where id = v.id and status = 'requires_approval';
    select * into v from public.aios_tool_invocations where id = v.id for update;
  end if;
  update public.aios_tool_invocations set status = 'executing', started_at = coalesce(started_at, now())
   where id = v.id and status = 'approved' returning * into v;
  if v.id is null then raise exception 'invocation was concurrently changed' using errcode = '40001'; end if;
  return v;
end $function$;
