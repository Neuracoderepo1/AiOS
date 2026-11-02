-- Committed fixtures for the eight-way concurrency job (G4). Local throwaway CI database only.
create schema if not exists cx;
create table cx.w (k text primary key, v text);

create function cx.wait_until(p_start timestamptz) returns void language plpgsql as $$
begin perform pg_sleep(greatest(0, extract(epoch from (p_start - clock_timestamp())))); end $$;

create function cx.resolve(p_start timestamptz, p_apr uuid, p_reviewer uuid) returns text language plpgsql as $$
declare st text;
begin
  perform cx.wait_until(p_start);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  begin perform public.aios_resolve_approval(p_apr, 'approved', p_reviewer, 'concurrency');
  exception when others then get stacked diagnostics st = returned_sqlstate; reset role; return st; end;
  reset role; return 'OK';
end $$;
create function cx.authz(p_start timestamptz, p_inv uuid) returns text language plpgsql as $$
declare st text;
begin
  perform cx.wait_until(p_start);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  begin perform public.aios_kernel_authorize_invocation(p_inv);
  exception when others then get stacked diagnostics st = returned_sqlstate; reset role; return st; end;
  reset role; return 'OK';
end $$;
create function cx.dup(p_start timestamptz, p_org uuid, p_agent uuid, p_key text, p_req uuid) returns text language plpgsql as $$
declare st text;
begin
  perform cx.wait_until(p_start);
  begin
    insert into public.aios_tool_invocations (organization_id, agent_id, tool_name, tool_key, arguments, risk_level, requested_by, idempotency_key, request_id)
    values (p_org, p_agent, 'support.search_tickets', 'support.search_tickets', '{"limit":3}', 'low', p_req, p_key, gen_random_uuid());
  exception when others then get stacked diagnostics st = returned_sqlstate; return st; end;
  return 'OK';
end $$;
create function cx.job(p_start timestamptz) returns text language plpgsql as $$
declare st text; r jsonb;
begin
  perform cx.wait_until(p_start);
  begin r := private.aios_expire_stale_approvals();
  exception when others then get stacked diagnostics st = returned_sqlstate; return 'ERR:' || st; end;
  return 'N:' || (r->>'approvals_expired');
end $$;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-8000-0000000c1001', 'authenticated', 'authenticated', 'cx-req@example.test'),
  ('00000000-0000-4000-8000-0000000c1002', 'authenticated', 'authenticated', 'cx-adm@example.test');
insert into public.aios_organizations (id, name) values ('c1c1c1c1-0000-4000-8000-000000000001', 'cx-org');
insert into public.aios_organization_members (organization_id, user_id, role) values
  ('c1c1c1c1-0000-4000-8000-000000000001', '00000000-0000-4000-8000-0000000c1001', 'member'),
  ('c1c1c1c1-0000-4000-8000-000000000001', '00000000-0000-4000-8000-0000000c1002', 'admin');
insert into public.aios_agents (id, organization_id, agent_key, name, role, status, authority) values
  ('c2c2c2c2-0000-4000-8000-000000000001', 'c1c1c1c1-0000-4000-8000-000000000001', 'cx-agent', 'cx', 'cx', 'idle',
   '{"risk_level":"medium","allowed_tools":["support.search_tickets","support.export_customer_data"],"limits":{}}');
insert into public.aios_contracts (organization_id, agent_id, version, risk_level, allowed_tools, limits, is_active)
values ('c1c1c1c1-0000-4000-8000-000000000001', 'c2c2c2c2-0000-4000-8000-000000000001', 1, 'medium',
        '["support.search_tickets","support.export_customer_data"]', '{}', true)
on conflict (agent_id, version) do update set is_active = true, allowed_tools = excluded.allowed_tools, risk_level = excluded.risk_level;

-- S1: one pending approval to resolve eight ways at once
insert into public.aios_tool_invocations (id, organization_id, agent_id, tool_name, tool_key, arguments, risk_level, requested_by, request_id)
values ('c3c3c3c3-0000-4000-8000-000000000001', 'c1c1c1c1-0000-4000-8000-000000000001', 'c2c2c2c2-0000-4000-8000-000000000001',
        'support.export_customer_data', 'support.export_customer_data', '{"format":"csv","scope":"s1"}', 'low',
        '00000000-0000-4000-8000-0000000c1001', gen_random_uuid());
-- S2: one approved, low-risk invocation to claim eight ways at once
insert into public.aios_tool_invocations (id, organization_id, agent_id, tool_name, tool_key, arguments, risk_level, requested_by, request_id)
values ('c3c3c3c3-0000-4000-8000-000000000002', 'c1c1c1c1-0000-4000-8000-000000000001', 'c2c2c2c2-0000-4000-8000-000000000001',
        'support.search_tickets', 'support.search_tickets', '{"limit":2}', 'low',
        '00000000-0000-4000-8000-0000000c1001', gen_random_uuid());
-- S4: 24 lapsed approvals for the expiry job to converge from eight workers at once
do $$
declare i int; v uuid;
begin
  for i in 1..24 loop
    insert into public.aios_tool_invocations (organization_id, agent_id, tool_name, tool_key, arguments, risk_level, requested_by, request_id)
    values ('c1c1c1c1-0000-4000-8000-000000000001', 'c2c2c2c2-0000-4000-8000-000000000001', 'support.export_customer_data', 'support.export_customer_data',
            jsonb_build_object('format', 'csv', 'scope', 's4-' || i), 'low', '00000000-0000-4000-8000-0000000c1001', gen_random_uuid())
    returning id into v;
    update public.aios_approvals set expires_at = now() - interval '5 minutes' where id = (select approval_id from public.aios_tool_invocations where id = v);
  end loop;
end $$;
