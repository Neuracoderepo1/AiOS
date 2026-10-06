
-- ============================================================
-- Development 1 + 2: lock down aios_agents / aios_contracts.
-- Previously both had a single `ALL` policy keyed only to org
-- membership — any ordinary member could rewrite an agent's
-- authority, risk ceiling, or allowed_tools directly. Confirmed
-- live before this migration: a 'member'-role user successfully
-- raised ARBITRON v4's risk_level to 'high' via a plain update.
-- ============================================================

drop policy if exists aios_agents_member on public.aios_agents;
create policy aios_agents_select on public.aios_agents
  for select to authenticated using (aios_is_org_member(organization_id));
create policy aios_agents_admin_insert on public.aios_agents
  for insert to authenticated with check (aios_is_org_admin(organization_id));
create policy aios_agents_admin_update on public.aios_agents
  for update to authenticated using (aios_is_org_admin(organization_id)) with check (aios_is_org_admin(organization_id));
create policy aios_agents_admin_delete on public.aios_agents
  for delete to authenticated using (aios_is_org_admin(organization_id));

drop policy if exists aios_contracts_member on public.aios_contracts;
create policy aios_contracts_select on public.aios_contracts
  for select to authenticated using (aios_is_org_member(organization_id));
create policy aios_contracts_admin_insert on public.aios_contracts
  for insert to authenticated with check (aios_is_org_admin(organization_id));
create policy aios_contracts_admin_update on public.aios_contracts
  for update to authenticated using (aios_is_org_admin(organization_id)) with check (aios_is_org_admin(organization_id));
-- No delete policy at all for aios_contracts: history is retired via is_active,
-- never deleted. Absence of a DELETE policy denies it by default under RLS.

-- ------------------------------------------------------------
-- Controlled RPCs. Each verifies caller identity, org admin
-- role, and target validity itself — never trusts the frontend
-- to have already checked this.
-- ------------------------------------------------------------

create or replace function public.aios_create_agent(
  p_organization_id uuid, p_name text, p_role text, p_primary_model text,
  p_risk_level text default 'low', p_allowed_tools jsonb default '[]'::jsonb,
  p_limits jsonb default '{}'::jsonb, p_department_id uuid default null
) returns public.aios_agents
language plpgsql security definer set search_path = public as $$
declare v_agent public.aios_agents; v_agent_key text;
begin
  if not aios_is_org_admin(p_organization_id) then
    raise exception 'only an organization owner/admin can create agents';
  end if;
  if p_risk_level not in ('low','medium','high') then
    raise exception 'risk_level must be low, medium, or high';
  end if;

  v_agent_key := lower(regexp_replace(p_name, '[^a-zA-Z0-9]+', '-', 'g')) || '-' || substr(gen_random_uuid()::text, 1, 8);

  insert into aios_agents (organization_id, department_id, agent_key, name, role, status, primary_model, trust_score, authority, metadata)
  values (p_organization_id, p_department_id, v_agent_key, p_name, p_role, 'idle', p_primary_model, 0,
          jsonb_build_object('risk_level', p_risk_level, 'allowed_tools', p_allowed_tools, 'limits', p_limits), '{}'::jsonb)
  returning * into v_agent;

  insert into aios_contracts (organization_id, agent_id, version, risk_level, allowed_tools, limits, is_active)
  values (p_organization_id, v_agent.id, 1, p_risk_level, p_allowed_tools, p_limits, true);

  insert into aios_audit_events (organization_id, agent_id, event_type, risk_level, action, decision, metadata)
  values (p_organization_id, v_agent.id, 'agent_created', p_risk_level, 'aios_create_agent', 'allow',
          jsonb_build_object('created_by', auth.uid(), 'agent_key', v_agent_key));

  return v_agent;
end; $$;

create or replace function public.aios_update_agent_authority(
  p_agent_id uuid, p_risk_level text, p_allowed_tools jsonb, p_limits jsonb
) returns public.aios_contracts
language plpgsql security definer set search_path = public as $$
declare v_org_id uuid; v_next_version int; v_contract public.aios_contracts;
begin
  select organization_id into v_org_id from aios_agents where id = p_agent_id;
  if v_org_id is null then raise exception 'agent not found'; end if;
  if not aios_is_org_admin(v_org_id) then
    raise exception 'only an organization owner/admin can change agent authority';
  end if;
  if p_risk_level not in ('low','medium','high') then
    raise exception 'risk_level must be low, medium, or high';
  end if;

  select coalesce(max(version), 0) + 1 into v_next_version from aios_contracts where agent_id = p_agent_id;

  update aios_contracts set is_active = false where agent_id = p_agent_id and is_active;

  insert into aios_contracts (organization_id, agent_id, version, risk_level, allowed_tools, limits, is_active)
  values (v_org_id, p_agent_id, v_next_version, p_risk_level, p_allowed_tools, p_limits, true)
  returning * into v_contract;

  -- Keep aios_agents.authority in sync — this is the column the enforcement
  -- trigger reads on every tool invocation, so it must never drift from the
  -- contract that's actually marked active.
  update aios_agents
  set authority = jsonb_build_object('risk_level', p_risk_level, 'allowed_tools', p_allowed_tools, 'limits', p_limits)
  where id = p_agent_id;

  insert into aios_audit_events (organization_id, agent_id, event_type, risk_level, action, decision, metadata)
  values (v_org_id, p_agent_id, 'agent_authority_changed', p_risk_level, 'aios_update_agent_authority', 'allow',
          jsonb_build_object('changed_by', auth.uid(), 'new_contract_version', v_next_version));

  return v_contract;
end; $$;

create or replace function public.aios_suspend_agent(p_agent_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_org_id uuid;
begin
  select organization_id into v_org_id from aios_agents where id = p_agent_id;
  if v_org_id is null then raise exception 'agent not found'; end if;
  if not aios_is_org_admin(v_org_id) then raise exception 'only an organization owner/admin can suspend agents'; end if;
  update aios_agents set status = 'suspended' where id = p_agent_id;
  insert into aios_audit_events (organization_id, agent_id, event_type, risk_level, action, decision, metadata)
  values (v_org_id, p_agent_id, 'agent_suspended', 'low', 'aios_suspend_agent', 'allow', jsonb_build_object('changed_by', auth.uid()));
end; $$;

create or replace function public.aios_reactivate_agent(p_agent_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_org_id uuid;
begin
  select organization_id into v_org_id from aios_agents where id = p_agent_id;
  if v_org_id is null then raise exception 'agent not found'; end if;
  if not aios_is_org_admin(v_org_id) then raise exception 'only an organization owner/admin can reactivate agents'; end if;
  update aios_agents set status = 'idle' where id = p_agent_id;
  insert into aios_audit_events (organization_id, agent_id, event_type, risk_level, action, decision, metadata)
  values (v_org_id, p_agent_id, 'agent_reactivated', 'low', 'aios_reactivate_agent', 'allow', jsonb_build_object('changed_by', auth.uid()));
end; $$;

grant execute on function public.aios_create_agent(uuid,text,text,text,text,jsonb,jsonb,uuid) to authenticated;
grant execute on function public.aios_update_agent_authority(uuid,text,jsonb,jsonb) to authenticated;
grant execute on function public.aios_suspend_agent(uuid) to authenticated;
grant execute on function public.aios_reactivate_agent(uuid) to authenticated;
