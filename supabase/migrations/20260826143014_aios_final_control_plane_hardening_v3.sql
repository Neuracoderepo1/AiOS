create extension if not exists pg_jsonschema with schema extensions;

revoke select (credential_reference) on public.aios_tools from anon, authenticated;
revoke insert (credential_reference), update (credential_reference), references (credential_reference) on public.aios_tools from service_role;
grant select (credential_reference) on public.aios_tools to service_role;
revoke select on public.aios_tools from anon, authenticated;
grant select (id, tool_key, name, description, version, category, risk_level, input_schema, output_schema, handler, status, is_enabled, requires_approval, timeout_ms, rate_limit, idempotency_required, external_service, capabilities, created_at, updated_at) on public.aios_tools to anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['aios_agents','aios_approvals','aios_audit_events','aios_contracts','aios_demo_support_tickets','aios_departments','aios_evaluations','aios_memory','aios_missions','aios_model_runs','aios_organization_members','aios_organizations','aios_projects','aios_tasks','aios_tool_invocations','aios_tools'] loop
    execute format('revoke references, trigger, truncate on public.%I from anon, authenticated', t);
  end loop;
end $$;

revoke execute on function public.aios_enforce_agent_authority() from public, anon, authenticated;
revoke execute on function public.aios_handle_new_user() from public, anon, authenticated;
revoke execute on function public.aios_log_mission_status_audit() from public, anon, authenticated;
revoke execute on function public.aios_log_task_status_audit() from public, anon, authenticated;
revoke execute on function public.aios_log_tool_invocation_audit() from public, anon, authenticated;
revoke execute on function public.aios_validate_agent_org() from public, anon, authenticated;
revoke execute on function public.aios_validate_mission_org() from public, anon, authenticated;
revoke execute on function public.aios_validate_task_agent_org() from public, anon, authenticated;
revoke execute on function public.aios_validate_task_org() from public, anon, authenticated;
revoke execute on function public.aios_prevent_self_role_change() from public, anon, authenticated;

create unique index if not exists aios_contracts_one_active_per_agent_idx on public.aios_contracts(agent_id) where is_active;

create or replace function private.aios_validate_invocation_registry() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t public.aios_tools;
begin
  select * into t from public.aios_tools where tool_key = coalesce(new.tool_key,new.tool_name);
  if t.id is null then raise exception 'tool is not registered' using errcode='22023'; end if;
  if not t.is_enabled or t.status <> 'active' then raise exception 'tool is disabled or inactive' using errcode='42501'; end if;
  if new.tool_key is distinct from t.tool_key or new.tool_name is distinct from t.tool_key then raise exception 'tool identity does not match canonical registry' using errcode='22023'; end if;
  if not extensions.jsonb_matches_schema(t.input_schema,new.arguments) then raise exception 'tool arguments do not match registry input schema' using errcode='22023'; end if;
  return new;
end $$;

drop trigger if exists trg_aios_validate_invocation_registry on public.aios_tool_invocations;
create trigger trg_aios_validate_invocation_registry before insert or update of tool_key,tool_name,arguments on public.aios_tool_invocations for each row execute function private.aios_validate_invocation_registry();

create or replace function private.aios_validate_tool_result_registry() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t public.aios_tools;
begin
  if new.status = 'succeeded' then
    select * into t from public.aios_tools where tool_key = new.tool_key;
    if t.id is null or not t.is_enabled or t.status <> 'active' then raise exception 'cannot succeed invocation for unavailable registry tool' using errcode='42501'; end if;
    if not extensions.jsonb_matches_schema(t.output_schema,coalesce(new.result,'null'::jsonb)) then raise exception 'tool result does not match registry output schema' using errcode='22023'; end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_aios_validate_tool_result_registry on public.aios_tool_invocations;
create trigger trg_aios_validate_tool_result_registry before update of status,result on public.aios_tool_invocations for each row execute function private.aios_validate_tool_result_registry();

create or replace function private.aios_bind_invocation_approval() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.aios_contracts;
begin
  if new.approval_id is not null then
    select * into c from public.aios_contracts where agent_id=new.agent_id and organization_id=new.organization_id and is_active order by version desc limit 1;
    if c.id is null then raise exception 'approval cannot bind without active contract'; end if;
    update public.aios_approvals set invocation_id=new.id, tool_key=new.tool_key, arguments_hash=encode(extensions.digest(convert_to(new.arguments::text,'UTF8'),'sha256'),'hex'), approval_version=c.version, expires_at=coalesce(expires_at,now()+interval '15 minutes') where id=new.approval_id and status='pending';
  end if;
  return new;
end $$;

drop trigger if exists trg_aios_bind_invocation_approval on public.aios_tool_invocations;
create trigger trg_aios_bind_invocation_approval after insert on public.aios_tool_invocations for each row execute function private.aios_bind_invocation_approval();

create or replace function private.aios_enforce_agent_authority() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_authority jsonb; v_limits jsonb; v_tool public.aios_tools; v_contract public.aios_contracts; v_risk_order jsonb := '{"low":1,"medium":2,"high":3}'::jsonb; v_agent_risk int; v_tool_risk int; v_requested_risk int; v_usd numeric; v_concurrent numeric; v_reason text; v_approval uuid;
begin
  select authority into v_authority from public.aios_agents where id=new.agent_id and organization_id=new.organization_id;
  if v_authority is null then new.status:='denied'; new.error_code:='AGENT_NOT_AUTHORIZED'; new.error_message:='agent authority not found'; return new; end if;
  select * into v_contract from public.aios_contracts where agent_id=new.agent_id and organization_id=new.organization_id and is_active order by version desc limit 1;
  if v_contract.id is null then new.status:='denied'; new.error_code:='NO_ACTIVE_CONTRACT'; new.error_message:='executable agent requires exactly one active contract'; return new; end if;
  select * into v_tool from public.aios_tools where tool_key=new.tool_key;
  if v_tool.id is null or not v_tool.is_enabled or v_tool.status <> 'active' then new.status:='denied'; new.error_code:='TOOL_UNAVAILABLE'; new.error_message:='tool is not active in canonical registry'; return new; end if;
  new.tool_key:=v_tool.tool_key; new.tool_name:=v_tool.tool_key; new.risk_level:=v_tool.risk_level; new.arguments_hash:=encode(extensions.digest(convert_to(new.arguments::text,'UTF8'),'sha256'),'hex'); new.authorization_version:=v_contract.version;
  v_limits:=coalesce(v_contract.limits,'{}'::jsonb); v_agent_risk:=(v_risk_order ->> v_contract.risk_level)::int; v_tool_risk:=(v_risk_order ->> v_tool.risk_level)::int; v_requested_risk:=(v_risk_order ->> new.risk_level)::int; v_usd:=nullif(new.arguments->>'usd_amount','')::numeric; v_concurrent:=nullif(new.arguments->>'concurrent_count','')::numeric;
  if not (v_contract.allowed_tools ? new.tool_key) then new.status:='denied'; new.error_code:='TOOL_NOT_AUTHORIZED'; v_reason:='tool is not authorized by active contract';
  elsif v_tool.requires_approval or coalesce((v_limits->>'requires_approval')::boolean,false) or v_tool_risk > v_agent_risk or v_requested_risk > v_agent_risk then new.status:='requires_approval'; v_reason:='mandatory approval policy applies';
  else new.status:='approved'; v_reason:='registry and active contract authorization passed'; end if;
  if v_usd is not null then
    if (v_limits ? 'max_disbursement') and v_usd > (v_limits->>'max_disbursement')::numeric then new.status:='denied'; new.error_code:='LIMIT_EXCEEDED'; v_reason:='USD amount exceeds hard contract limit';
    elsif (v_limits ? 'max_position_usd') and v_usd > (v_limits->>'max_position_usd')::numeric then new.status:='denied'; new.error_code:='LIMIT_EXCEEDED'; v_reason:='USD amount exceeds hard contract limit';
    elsif (v_limits ? 'requires_approval_above_usd') and v_usd > (v_limits->>'requires_approval_above_usd')::numeric then new.status:='requires_approval'; v_reason:='USD amount exceeds approval threshold'; end if;
  elsif (v_limits ? 'max_disbursement') or (v_limits ? 'max_position_usd') then new.status:='requires_approval'; v_reason:='USD amount required to verify contract ceiling'; end if;
  if v_concurrent is not null then
    if (v_limits ? 'max_concurrent_positions') and v_concurrent >= (v_limits->>'max_concurrent_positions')::numeric then new.status:='denied'; new.error_code:='CONCURRENCY_LIMIT'; v_reason:='concurrency limit exceeded';
    elsif (v_limits ? 'max_concurrent') and v_concurrent >= (v_limits->>'max_concurrent')::numeric then new.status:='denied'; new.error_code:='CONCURRENCY_LIMIT'; v_reason:='concurrency limit exceeded'; end if;
  elsif (v_limits ? 'max_concurrent_positions') or (v_limits ? 'max_concurrent') then new.status:='requires_approval'; v_reason:='concurrency count required to verify contract ceiling'; end if;
  new.result:=coalesce(new.result,'{}'::jsonb)||jsonb_build_object('kernel_reason',coalesce(v_reason,'authorization decision'));
  if new.status='requires_approval' then insert into public.aios_approvals(organization_id,agent_id,task_id,action,risk_level,status,reason,tool_key,approval_version) values(new.organization_id,new.agent_id,new.task_id,new.tool_key,new.risk_level,'pending',v_reason,new.tool_key,v_contract.version) returning id into v_approval; new.approval_id:=v_approval; end if;
  return new;
end $$;

create or replace function private.aios_kernel_authorize_invocation(p_invocation_id uuid) returns public.aios_tool_invocations language plpgsql security definer set search_path = '' as $$
declare v public.aios_tool_invocations; c public.aios_contracts; a public.aios_approvals; t public.aios_tools;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then raise exception 'service-role execution context required' using errcode='42501'; end if;
  select * into v from public.aios_tool_invocations where id=p_invocation_id for update; if v.id is null then raise exception 'invocation not found' using errcode='P0002'; end if;
  select * into c from public.aios_contracts where agent_id=v.agent_id and organization_id=v.organization_id and is_active order by version desc limit 1; if c.id is null then raise exception 'no active contract' using errcode='42501'; end if;
  select * into t from public.aios_tools where tool_key=v.tool_key; if t.id is null or not t.is_enabled or t.status <> 'active' then raise exception 'tool unavailable' using errcode='42501'; end if;
  if not extensions.jsonb_matches_schema(t.input_schema,v.arguments) then raise exception 'invocation arguments fail registry schema' using errcode='22023'; end if;
  if v.authorization_version is distinct from c.version then raise exception 'authorization version is stale' using errcode='40901'; end if;
  if v.status='requires_approval' or t.requires_approval or coalesce((c.limits->>'requires_approval')::boolean,false) then
    select * into a from public.aios_approvals where id=v.approval_id and invocation_id=v.id for update; if a.id is null or a.status <> 'approved' or (a.expires_at is not null and a.expires_at<=now()) then raise exception 'valid approval required' using errcode='42501'; end if;
    if a.arguments_hash is distinct from v.arguments_hash or a.approval_version is distinct from c.version or a.tool_key is distinct from v.tool_key then raise exception 'approval no longer matches invocation authorization context' using errcode='42501'; end if;
  end if;
  if v.status not in ('approved','requires_approval') then if v.status='executing' then return v; else raise exception 'invocation is not executable: %',v.status using errcode='40001'; end if; end if;
  if v.status='requires_approval' then update public.aios_tool_invocations set status='approved' where id=v.id and status='requires_approval'; select * into v from public.aios_tool_invocations where id=v.id for update; end if;
  update public.aios_tool_invocations set status='executing',started_at=coalesce(started_at,now()) where id=v.id and status='approved' returning * into v; if v.id is null then raise exception 'invocation was concurrently changed' using errcode='40001'; end if; return v;
end $$;

revoke execute on function private.aios_validate_invocation_registry() from public,anon,authenticated;
revoke execute on function private.aios_validate_tool_result_registry() from public,anon,authenticated;
revoke execute on function private.aios_bind_invocation_approval() from public,anon,authenticated;
revoke execute on function private.aios_enforce_agent_authority() from public,anon,authenticated;
revoke execute on function private.aios_kernel_authorize_invocation(uuid) from public,anon,authenticated;
