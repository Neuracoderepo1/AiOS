-- AiOS certification matrix (46 cases / 9 domains). This file runs 45 of them; G4 (eight-way concurrency) is multi-session and
-- runs in tests/concurrency/run.sh. Every case drives the REAL kernel (triggers, RLS, grants, canonical RPCs) under real roles
-- and JWT claims. Runs on a throwaway local database inside one transaction that is rolled back. Nothing here touches production.
-- Fixtures are created with normal inserts (all integrity triggers ON) except F7, which needs a legacy-shaped row and uses
-- session_replication_role = replica for that single INSERT only.
begin;

create schema mx;
grant usage on schema mx to public;
create table mx.results (seq bigserial primary key, id text, domain text, ok boolean, detail text);
create table mx.w (k text primary key, v text);
grant all on all tables in schema mx to public;
grant all on all sequences in schema mx to public;

create function mx.rec(p_id text, p_domain text, p_ok boolean, p_detail text default null) returns void language sql as
$$ insert into mx.results(id, domain, ok, detail) values (p_id, p_domain, coalesce(p_ok, false), p_detail) $$;
create function mx.put(p_k text, p_v text) returns void language sql as
$$ insert into mx.w values (p_k, p_v) on conflict (k) do update set v = excluded.v $$;
create function mx.u(p_k text) returns uuid language sql stable as $$ select v::uuid from mx.w where k = p_k $$;

create function mx.reset_ctx() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function mx.set_ctx(p_role text, p_uid uuid, p_jwt_role text default null) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims',
    case when p_uid is null then jsonb_build_object('role', coalesce(p_jwt_role, p_role))::text
         else jsonb_build_object('sub', p_uid, 'role', coalesce(p_jwt_role, p_role))::text end, true);
  if p_role <> 'postgres' then execute format('set local role %I', p_role); end if;
end $$;
-- Run a single-value SELECT under a role/claims. Returns the value as text, 'NULL', or 'ERR:<sqlstate>'.
create function mx.q(p_role text, p_uid uuid, p_sql text, p_jwt_role text default null) returns text language plpgsql as $$
declare r text; st text;
begin
  perform mx.set_ctx(p_role, p_uid, p_jwt_role);
  begin execute p_sql into r; exception when others then get stacked diagnostics st = returned_sqlstate; r := 'ERR:' || st; end;
  perform mx.reset_ctx();
  return coalesce(r, 'NULL');
end $$;
-- Run a statement under a role/claims. Returns 'OK' or 'ERR:<sqlstate>'.
create function mx.dml(p_role text, p_uid uuid, p_sql text) returns text language plpgsql as $$
declare st text;
begin
  perform mx.set_ctx(p_role, p_uid);
  begin execute p_sql; exception when others then get stacked diagnostics st = returned_sqlstate; perform mx.reset_ctx(); return 'ERR:' || st; end;
  perform mx.reset_ctx();
  return 'OK';
end $$;
-- Run a statement as the database owner. Returns the sqlstate raised, or 'NONE'.
create function mx.err(p_sql text) returns text language plpgsql as $$
declare st text;
begin
  perform mx.reset_ctx();
  begin execute p_sql; exception when others then get stacked diagnostics st = returned_sqlstate; return st; end;
  return 'NONE';
end $$;
create function mx.hidden(p_uid uuid, p_tbl text, p_org uuid) returns boolean language sql as $$
  select mx.q('authenticated', p_uid, format('select count(*) from public.%I where organization_id = %L', p_tbl, p_org)) in ('0', 'ERR:42501') $$;

-- Canonical kernel calls, always as service_role with a service_role JWT.
create function mx.authz(p_inv uuid) returns text language plpgsql as $$
declare st text; msg text;
begin
  perform mx.set_ctx('service_role', null, 'service_role');
  begin perform public.aios_kernel_authorize_invocation(p_inv);
  exception when others then get stacked diagnostics st = returned_sqlstate, msg = message_text; perform mx.reset_ctx(); return st || '|' || left(msg, 90); end;
  perform mx.reset_ctx();
  return 'OK';
end $$;
create function mx.resolve(p_apr uuid, p_decision text, p_reviewer uuid) returns text language plpgsql as $$
declare st text; msg text;
begin
  perform mx.set_ctx('service_role', null, 'service_role');
  begin perform public.aios_resolve_approval(p_apr, p_decision, p_reviewer, 'matrix');
  exception when others then get stacked diagnostics st = returned_sqlstate, msg = message_text; perform mx.reset_ctx(); return st || '|' || left(msg, 90); end;
  perform mx.reset_ctx();
  return 'OK';
end $$;

-- Fixture builders (run as owner, triggers ON).
create function mx.agent(p_org uuid, p_key text, p_status text, p_risk text, p_tools jsonb, p_limits jsonb, p_contract boolean) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform mx.reset_ctx();
  insert into public.aios_agents (organization_id, agent_key, name, role, status, authority)
  values (p_org, p_key, p_key, 'matrix', p_status, jsonb_build_object('risk_level', p_risk, 'allowed_tools', p_tools, 'limits', p_limits))
  returning id into v;
  if p_contract then
    insert into public.aios_contracts (organization_id, agent_id, version, risk_level, allowed_tools, limits, is_active)
    values (p_org, v, 1, p_risk, p_tools, p_limits, true)
    on conflict (agent_id, version) do update set risk_level = excluded.risk_level, allowed_tools = excluded.allowed_tools, limits = excluded.limits, is_active = true;
  end if;
  return v;
end $$;
create function mx.mk_inv(p_org uuid, p_agent uuid, p_tool text, p_args jsonb, p_req uuid, p_idem text default null) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform mx.reset_ctx();
  insert into public.aios_tool_invocations (organization_id, agent_id, tool_name, tool_key, arguments, risk_level, requested_by, idempotency_key, request_id)
  values (p_org, p_agent, p_tool, p_tool, p_args, 'low', p_req, p_idem, gen_random_uuid()) returning id into v;
  return v;
end $$;
create function mx.inv(p_k text, p_org uuid, p_agent uuid, p_tool text, p_args jsonb, p_req uuid) returns uuid language plpgsql as $$
declare v uuid;
begin v := mx.mk_inv(p_org, p_agent, p_tool, p_args, p_req); perform mx.put(p_k, v::text); return v; end $$;
create function mx.st(p_inv uuid) returns text language sql as $$ select status from public.aios_tool_invocations where id = p_inv $$;
create function mx.apr(p_inv uuid) returns uuid language sql as $$ select approval_id from public.aios_tool_invocations where id = p_inv $$;

-- ------------------------------------------------------------------ world
insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-8000-000000001001', 'authenticated', 'authenticated', 'mx-req@example.test'),
  ('00000000-0000-4000-8000-000000001002', 'authenticated', 'authenticated', 'mx-adm@example.test'),
  ('00000000-0000-4000-8000-000000001003', 'authenticated', 'authenticated', 'mx-admb@example.test'),
  ('00000000-0000-4000-8000-000000001004', 'authenticated', 'authenticated', 'mx-mem@example.test'),
  ('00000000-0000-4000-8000-000000001005', 'authenticated', 'authenticated', 'mx-out@example.test');
select mx.put('u_req', '00000000-0000-4000-8000-000000001001'), mx.put('u_adm', '00000000-0000-4000-8000-000000001002'),
       mx.put('u_admb', '00000000-0000-4000-8000-000000001003'), mx.put('u_mem', '00000000-0000-4000-8000-000000001004'),
       mx.put('u_out', '00000000-0000-4000-8000-000000001005'),
       mx.put('orgA', 'a1a1a1a1-0000-4000-8000-000000000001'), mx.put('orgB', 'b2b2b2b2-0000-4000-8000-000000000002');
insert into public.aios_organizations (id, name) values (mx.u('orgA'), 'mx-org-a'), (mx.u('orgB'), 'mx-org-b');
insert into public.aios_organization_members (organization_id, user_id, role) values
  (mx.u('orgA'), mx.u('u_req'), 'member'), (mx.u('orgA'), mx.u('u_adm'), 'admin'), (mx.u('orgA'), mx.u('u_mem'), 'member'),
  (mx.u('orgB'), mx.u('u_admb'), 'admin');

insert into public.aios_tools (tool_key, name, description, version, category, risk_level, input_schema, output_schema, handler, status, is_enabled, requires_approval)
values ('mx.payment', 'MX Payment', 'matrix payment tool', 1, 'matrix', 'medium',
        '{"type":"object","properties":{"usd_amount":{"type":"number"},"concurrent_count":{"type":"integer"}},"additionalProperties":false}',
        '{"type":"object"}', 'mx.payment', 'active', true, false);
-- The kernel hard-allowlists executor keys in private.aios_validate_executor_registry (deliberate production policy; this test must
-- not widen it). The fixture tool therefore reuses an already-allowlisted key so that cases E3/E4 exercise the budget limits,
-- not the executor allowlist. Allowlist enforcement itself is asserted in tests/sql/06_executor_allowlist.sql.
insert into private.aios_trusted_executors (tool_key, executor_key, is_enabled) values ('mx.payment', 'support.search_tickets.v1', true);

select mx.put('a1',       mx.agent(mx.u('orgA'), 'mx-a1',     'idle',      'medium', '["support.search_tickets","support.export_customer_data"]', '{}', true)::text),
       mx.put('a_sus',    mx.agent(mx.u('orgA'), 'mx-sus',    'suspended', 'medium', '["support.search_tickets","support.export_customer_data"]', '{}', true)::text),
       mx.put('a_nocon',  mx.agent(mx.u('orgA'), 'mx-nocon',  'idle',      'low',    '[]', '{}', false)::text),
       mx.put('a_low',    mx.agent(mx.u('orgA'), 'mx-low',    'idle',      'low',    '["support.search_tickets","support.export_customer_data"]', '{}', true)::text),
       mx.put('a_narrow', mx.agent(mx.u('orgA'), 'mx-narrow', 'idle',      'medium', '["support.search_tickets"]', '{}', true)::text),
       mx.put('a_pay',    mx.agent(mx.u('orgA'), 'mx-pay',    'idle',      'medium', '["mx.payment"]', '{"max_usd":100,"requires_approval_above_usd":50,"max_concurrent":3}', true)::text),
       mx.put('a_ver',    mx.agent(mx.u('orgA'), 'mx-ver',    'idle',      'medium', '["support.search_tickets"]', '{}', true)::text),
       mx.put('a_b',      mx.agent(mx.u('orgB'), 'mx-b',      'idle',      'medium', '["support.search_tickets"]', '{}', true)::text);

insert into public.aios_tasks (id, organization_id, title) values
  ('c0c0c0c0-0000-4000-8000-00000000000a', mx.u('orgA'), 'mx task a'), ('c0c0c0c0-0000-4000-8000-00000000000b', mx.u('orgB'), 'mx task b');
select mx.put('taskA', 'c0c0c0c0-0000-4000-8000-00000000000a'), mx.put('taskB', 'c0c0c0c0-0000-4000-8000-00000000000b');
-- org B has an invocation (and therefore audit rows and possibly an approval) so isolation checks are not vacuous
select mx.inv('b_inv', mx.u('orgB'), mx.u('a_b'), 'support.search_tickets', '{"limit":1}', mx.u('u_admb'));

-- ------------------------------------------------------------------ cases
do $$
declare
  A uuid := mx.u('orgA'); B uuid := mx.u('orgB');
  req uuid := mx.u('u_req'); adm uuid := mx.u('u_adm'); admb uuid := mx.u('u_admb'); mem uuid := mx.u('u_mem'); outu uuid := mx.u('u_out');
  s text := '{"limit":5}'; x text := '{"format":"csv","scope":"all"}';
  v uuid; v2 uuid; ap uuid; r text; r2 text;
begin
  -- ===== Authentication and identity (A1-A5)
  begin
    perform mx.rec('A1', 'Authentication and identity', mx.q('authenticated', adm, format('select public.aios_current_org_role(%L)', A)) = 'admin', 'valid identity resolves its org role');
  exception when others then perform mx.rec('A1', 'Authentication and identity', false, sqlstate || ': ' || sqlerrm); end;
  begin
    perform mx.rec('A2', 'Authentication and identity', mx.q('authenticated', null, format('select public.aios_current_org_role(%L)', A)) = 'NULL', 'missing identity has no role');
  exception when others then perform mx.rec('A2', 'Authentication and identity', false, sqlstate || ': ' || sqlerrm); end;
  begin
    perform mx.rec('A3', 'Authentication and identity', mx.q('authenticated', gen_random_uuid(), format('select public.aios_current_org_role(%L)', A)) = 'NULL', 'unknown identity has no role');
  exception when others then perform mx.rec('A3', 'Authentication and identity', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.q('authenticated', mem, format('select count(*) from public.aios_tasks where organization_id = %L', A));
    r2 := mx.q('authenticated', outu, format('select count(*) from public.aios_tasks where organization_id = %L', A));
    perform mx.rec('A4', 'Authentication and identity', r::int > 0 and r2 = '0', 'member sees ' || r || ', outsider sees ' || r2 || ' within one session');
  exception when others then perform mx.rec('A4', 'Authentication and identity', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.mk_inv(A, mx.u('a1'), 'support.search_tickets', s::jsonb, req);
    r := mx.q('service_role', null, format('select (public.aios_kernel_authorize_invocation(%L)).id::text', v), 'authenticated');
    r2 := mx.authz(v);
    perform mx.rec('A5', 'Authentication and identity', r = 'ERR:42501' and r2 = 'OK', 'service db role without service JWT: ' || r || '; with service JWT: ' || r2);
  exception when others then perform mx.rec('A5', 'Authentication and identity', false, sqlstate || ': ' || sqlerrm); end;

  -- ===== Organization isolation (B1-B6)
  begin
    perform mx.rec('B1', 'Organization isolation',
      (select count(*) from public.aios_tool_invocations where organization_id = B) > 0
      and mx.hidden(adm, 'aios_tasks', B) and mx.hidden(adm, 'aios_tool_invocations', B) and mx.hidden(adm, 'aios_approvals', B)
      and mx.hidden(adm, 'aios_agents', B) and mx.hidden(adm, 'aios_audit_events', B), 'org A admin cannot see org B rows');
  exception when others then perform mx.rec('B1', 'Organization isolation', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.dml('authenticated', mem, format('insert into public.aios_tasks (organization_id, title) values (%L, %L)', B, 'x-tenant write'));
    perform mx.rec('B2', 'Organization isolation', r = 'ERR:42501', 'cross-tenant insert: ' || r);
  exception when others then perform mx.rec('B2', 'Organization isolation', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.err(format('select mx.mk_inv(%L, %L, ''support.search_tickets'', ''{"limit":1}'', %L)', A, mx.u('a_b'), req));
    perform mx.rec('B3', 'Organization isolation', r <> 'NONE', 'org A invocation with org B agent refused: ' || r);
  exception when others then perform mx.rec('B3', 'Organization isolation', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.err(format('insert into public.aios_approvals (organization_id, task_id, action, risk_level, status) values (%L, %L, ''x'', ''low'', ''pending'')', A, mx.u('taskB')));
    perform mx.rec('B4', 'Organization isolation', r = '23514', 'approval bound to another org''s task: ' || r);
  exception when others then perform mx.rec('B4', 'Organization isolation', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('b5', A, mx.u('a1'), 'support.export_customer_data', x::jsonb, req);
    r := mx.resolve(mx.apr(v), 'approved', admb);
    perform mx.rec('B5', 'Organization isolation', mx.st(v) = 'requires_approval' and r like '42501%', 'org B admin resolving org A approval: ' || r);
  exception when others then perform mx.rec('B5', 'Organization isolation', false, sqlstate || ': ' || sqlerrm); end;
  begin
    perform mx.rec('B6', 'Organization isolation',
      (select count(*) from public.aios_organization_members where organization_id = B) > 0 and mx.hidden(adm, 'aios_organization_members', B), 'membership rows of another org are invisible');
  exception when others then perform mx.rec('B6', 'Organization isolation', false, sqlstate || ': ' || sqlerrm); end;

  -- ===== Agent registry and trust (C1-C5)
  begin
    v := mx.inv('c1', A, mx.u('a1'), 'support.search_tickets', s::jsonb, req);
    perform mx.rec('C1', 'Agent registry and trust', mx.st(v) = 'approved', 'registered agent, in-contract tool: ' || mx.st(v));
  exception when others then perform mx.rec('C1', 'Agent registry and trust', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.err(format('select mx.mk_inv(%L, %L, ''support.search_tickets'', ''{"limit":1}'', %L)', A, gen_random_uuid(), req));
    perform mx.rec('C2', 'Agent registry and trust', r <> 'NONE', 'unknown agent refused: ' || r);
  exception when others then perform mx.rec('C2', 'Agent registry and trust', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('c3', A, mx.u('a_sus'), 'support.search_tickets', s::jsonb, req);
    perform mx.rec('C3', 'Agent registry and trust', mx.st(v) = 'denied' and mx.authz(v) <> 'OK', 'suspended agent: ' || mx.st(v));
  exception when others then perform mx.rec('C3', 'Agent registry and trust', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.q('authenticated', adm, format('select (public.aios_agent_trust_explain(%L))::jsonb ? ''error''', mx.u('a1')));
    r2 := mx.q('authenticated', outu, format('select (public.aios_agent_trust_explain(%L))::jsonb ? ''error''', mx.u('a1')));
    perform mx.rec('C4', 'Agent registry and trust', r = 'false' and r2 = 'true', 'trust report: member=' || r || ' (error key), outsider=' || r2);
  exception when others then perform mx.rec('C4', 'Agent registry and trust', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('c5', A, mx.u('a_narrow'), 'support.export_customer_data', x::jsonb, req);
    r := mx.resolve(mx.apr(v), 'approved', adm);
    r2 := mx.authz(v);
    perform mx.rec('C5', 'Agent registry and trust', mx.st(v) in ('requires_approval', 'approved') and r2 like '42501%', 'tool outside contract, even if approved: ' || r2);
  exception when others then perform mx.rec('C5', 'Agent registry and trust', false, sqlstate || ': ' || sqlerrm); end;

  -- ===== Tool registry and contracts (D1-D5)
  begin
    r := mx.err(format('select mx.mk_inv(%L, %L, ''nope.unknown'', ''{}'', %L)', A, mx.u('a1'), req));
    if r = 'NONE' then
      v := (select id from public.aios_tool_invocations where tool_key = 'nope.unknown' or tool_name = 'nope.unknown' order by created_at desc limit 1);
      perform mx.rec('D1', 'Tool registry and contracts', mx.st(v) = 'denied' and mx.authz(v) <> 'OK', 'unknown tool recorded as denied');
    else
      perform mx.rec('D1', 'Tool registry and contracts', true, 'unknown tool refused at insert: ' || r);
    end if;
  exception when others then perform mx.rec('D1', 'Tool registry and contracts', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('d2', A, mx.u('a_nocon'), 'support.search_tickets', s::jsonb, req);
    perform mx.rec('D2', 'Tool registry and contracts', mx.st(v) = 'denied' and mx.authz(v) <> 'OK', 'agent without an active contract: ' || mx.st(v));
  exception when others then perform mx.rec('D2', 'Tool registry and contracts', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.err(format('select mx.mk_inv(%L, %L, ''support.search_tickets'', ''{"limit":"abc"}'', %L)', A, mx.u('a1'), req));
    if r = 'NONE' then
      v := (select id from public.aios_tool_invocations where tool_key = 'support.search_tickets' and arguments = '{"limit":"abc"}'::jsonb order by created_at desc limit 1);
      perform mx.rec('D3', 'Tool registry and contracts', mx.authz(v) <> 'OK', 'schema violation refused at authorization');
    else
      perform mx.rec('D3', 'Tool registry and contracts', true, 'schema violation refused at insert: ' || r);
    end if;
  exception when others then perform mx.rec('D3', 'Tool registry and contracts', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('d4', A, mx.u('a_ver'), 'support.search_tickets', s::jsonb, req);
    update public.aios_contracts set is_active = false where agent_id = mx.u('a_ver');
    insert into public.aios_contracts (organization_id, agent_id, version, risk_level, allowed_tools, limits, is_active)
      values (A, mx.u('a_ver'), 2, 'medium', '["support.search_tickets"]', '{}', true);
    r := mx.authz(v);
    perform mx.rec('D4', 'Tool registry and contracts', mx.st(v) = 'approved' and r like '40901%', 'request under v1, contract now v2: ' || r);
  exception when others then perform mx.rec('D4', 'Tool registry and contracts', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.mk_inv(A, mx.u('a1'), 'support.search_tickets', s::jsonb, req);
    update public.aios_tools set is_enabled = false where tool_key = 'support.search_tickets';
    r := mx.authz(v);
    update public.aios_tools set is_enabled = true where tool_key = 'support.search_tickets';
    perform mx.rec('D5', 'Tool registry and contracts', mx.st(v) = 'approved' and r like '42501%', 'tool disabled after request: ' || r);
  exception when others then perform mx.rec('D5', 'Tool registry and contracts', false, sqlstate || ': ' || sqlerrm); end;

  -- ===== Risk and budget controls (E1-E5)
  begin
    v := mx.inv('e1', A, mx.u('a_low'), 'support.export_customer_data', x::jsonb, req);
    r := mx.resolve(mx.apr(v), 'approved', adm);
    r2 := mx.authz(v);
    perform mx.rec('E1', 'Risk and budget controls', r2 like '42501%', 'medium-risk tool above a low contract ceiling, even if approved: ' || r2);
  exception when others then perform mx.rec('E1', 'Risk and budget controls', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('e2', A, mx.u('a_pay'), 'mx.payment', '{"usd_amount":500,"concurrent_count":1}'::jsonb, req);
    perform mx.rec('E2', 'Risk and budget controls', mx.st(v) = 'denied' and mx.authz(v) <> 'OK', 'USD above hard limit: ' || mx.st(v));
  exception when others then perform mx.rec('E2', 'Risk and budget controls', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.mk_inv(A, mx.u('a_pay'), 'mx.payment', '{"usd_amount":50,"concurrent_count":1}'::jsonb, req);
    v2 := mx.mk_inv(A, mx.u('a_pay'), 'mx.payment', '{"usd_amount":51,"concurrent_count":1}'::jsonb, req);
    r := mx.authz(v); r2 := mx.authz(v2);
    perform mx.rec('E3', 'Risk and budget controls', mx.st(v) = 'executing' and r = 'OK' and mx.st(v2) = 'requires_approval' and r2 like '42501%', 'at threshold: ' || r || '; one above: ' || r2);
  exception when others then perform mx.rec('E3', 'Risk and budget controls', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.mk_inv(A, mx.u('a_pay'), 'mx.payment', '{"usd_amount":10,"concurrent_count":3}'::jsonb, req);
    v2 := mx.mk_inv(A, mx.u('a_pay'), 'mx.payment', '{"usd_amount":10,"concurrent_count":2}'::jsonb, req);
    perform mx.rec('E4', 'Risk and budget controls', mx.st(v) = 'denied' and mx.authz(v) <> 'OK' and mx.authz(v2) = 'OK', 'concurrency at limit denied, below limit allowed');
  exception when others then perform mx.rec('E4', 'Risk and budget controls', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.mk_inv(A, mx.u('a_pay'), 'mx.payment', '{"concurrent_count":1}'::jsonb, req);
    r := mx.authz(v);
    perform mx.rec('E5', 'Risk and budget controls', mx.st(v) = 'requires_approval' and r like '42501%', 'missing usd_amount fails closed: ' || r);
  exception when others then perform mx.rec('E5', 'Risk and budget controls', false, sqlstate || ': ' || sqlerrm); end;

  -- ===== Approval lifecycle (F1-F7)
  begin
    v := mx.inv('f1', A, mx.u('a1'), 'support.export_customer_data', x::jsonb, req); ap := mx.apr(v);
    r := mx.authz(v);
    perform mx.rec('F1', 'Approval lifecycle', mx.st(v) = 'requires_approval' and (select status = 'pending' and expires_at is not null from public.aios_approvals where id = ap) and r like '42501%', 'approval required before execution: ' || r);
  exception when others then perform mx.rec('F1', 'Approval lifecycle', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('f2', A, mx.u('a1'), 'support.export_customer_data', x::jsonb, req); ap := mx.apr(v);
    r := mx.resolve(ap, 'approved', adm);
    r2 := mx.authz(v);
    perform mx.rec('F2', 'Approval lifecycle', r = 'OK' and r2 = 'OK' and mx.st(v) = 'executing', 'authorized reviewer: resolve=' || r || ', execute=' || r2);
  exception when others then perform mx.rec('F2', 'Approval lifecycle', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.mk_inv(A, mx.u('a1'), 'support.export_customer_data', x::jsonb, adm); ap := mx.apr(v);
    r := mx.resolve(ap, 'approved', adm);
    r2 := mx.authz(v);
    perform mx.rec('F3', 'Approval lifecycle', mx.st(v) <> 'executing' and r2 like '42501%', 'self-approval cannot execute (resolve=' || r || '): ' || r2);
  exception when others then perform mx.rec('F3', 'Approval lifecycle', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('f4', A, mx.u('a1'), 'support.export_customer_data', x::jsonb, req); ap := mx.apr(v);
    update public.aios_approvals set expires_at = now() - interval '1 minute' where id = ap;
    r := mx.resolve(ap, 'approved', adm);
    perform private.aios_expire_stale_approvals();
    perform mx.rec('F4', 'Approval lifecycle',
      r like '40001%' and (select status from public.aios_approvals where id = ap) = 'expired' and mx.st(v) = 'expired' and mx.authz(v) <> 'OK',
      'lapsed approval: resolve=' || r || ', approval=' || (select status from public.aios_approvals where id = ap) || ', invocation=' || mx.st(v));
  exception when others then perform mx.rec('F4', 'Approval lifecycle', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('f5', A, mx.u('a1'), 'support.export_customer_data', x::jsonb, req); ap := mx.apr(v);
    r := mx.resolve(ap, 'rejected', adm);
    perform mx.rec('F5', 'Approval lifecycle', r = 'OK' and mx.st(v) = 'denied' and mx.authz(v) <> 'OK', 'rejection denies the invocation: ' || mx.st(v));
  exception when others then perform mx.rec('F5', 'Approval lifecycle', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('f6', A, mx.u('a1'), 'support.export_customer_data', x::jsonb, req); ap := mx.apr(v);
    r := mx.resolve(ap, 'approved', adm); r2 := mx.resolve(ap, 'approved', adm);
    perform mx.rec('F6', 'Approval lifecycle', r = 'OK' and r2 like '40001%' and mx.authz(v) = 'OK' and mx.authz(v) like '40001%', 'replayed decision and replayed execution both refused');
  exception when others then perform mx.rec('F6', 'Approval lifecycle', false, sqlstate || ': ' || sqlerrm); end;
  begin
    -- Legacy-shaped row (cross-org agent binding) that today's guards would refuse to create: replica role for this INSERT only.
    set local session_replication_role = replica;
    insert into public.aios_approvals (id, organization_id, agent_id, action, risk_level, status, created_at)
      values ('f7f7f7f7-0000-4000-8000-000000000007', A, mx.u('a_b'), 'x', 'low', 'pending', now() - interval '3 days');
    set local session_replication_role = origin;
    r := private.aios_approval_binding_defect('f7f7f7f7-0000-4000-8000-000000000007');
    perform private.aios_expire_stale_approvals();
    perform mx.rec('F7', 'Approval lifecycle',
      r = 'agent_organization_mismatch' and (select status from public.aios_approvals where id = 'f7f7f7f7-0000-4000-8000-000000000007') = 'pending'
      and exists (select 1 from public.aios_backlog_dispositions where entity_id = 'f7f7f7f7-0000-4000-8000-000000000007' and disposition = 'manual_review')
      and (select tgenabled = 'O' from pg_trigger where tgname = 'trg_aios_validate_approval_integrity'),
      'invalid binding detected (' || r || '), left pending, manual_review recorded, guard enabled');
  exception when others then
    set local session_replication_role = origin;
    perform mx.rec('F7', 'Approval lifecycle', false, sqlstate || ': ' || sqlerrm);
  end;

  -- ===== Execution and idempotency (G1-G3, G5; G4 is tests/concurrency/run.sh)
  begin
    perform mx.mk_inv(A, mx.u('a1'), 'support.search_tickets', s::jsonb, req, 'mx-idem-1');
    r := mx.err(format('select mx.mk_inv(%L, %L, ''support.search_tickets'', %L, %L, ''mx-idem-1'')', A, mx.u('a1'), s, req));
    perform mx.rec('G1', 'Execution and idempotency', r = '23505', 'duplicate idempotency key: ' || r);
  exception when others then perform mx.rec('G1', 'Execution and idempotency', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.mk_inv(A, mx.u('a1'), 'support.search_tickets', s::jsonb, req);
    r := mx.authz(v); r2 := mx.authz(v);
    perform mx.rec('G2', 'Execution and idempotency', r = 'OK' and r2 like '40001%', 'retry of a claimed invocation refused: ' || r2);
  exception when others then perform mx.rec('G2', 'Execution and idempotency', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.inv('g3', A, mx.u('a1'), 'support.search_tickets', s::jsonb, req);
    r := mx.authz(v);
    update public.aios_tool_invocations set status = 'failed', completed_at = now(), error_code = 'MX_EXEC_FAILURE', error_message = 'matrix failure' where id = v;
    perform mx.rec('G3', 'Execution and idempotency', r = 'OK' and mx.st(v) = 'failed' and (select error_code from public.aios_tool_invocations where id = v) = 'MX_EXEC_FAILURE', 'execution failure recorded');
  exception when others then perform mx.rec('G3', 'Execution and idempotency', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.mk_inv(A, mx.u('a1'), 'support.export_customer_data', x::jsonb, req);
    r := mx.err(format('update public.aios_tool_invocations set status = ''executing'' where id = %L', v));
    perform mx.rec('G5', 'Execution and idempotency', r <> 'NONE' and mx.st(v) = 'requires_approval', 'cannot skip authorization by writing status: ' || r);
  exception when others then perform mx.rec('G5', 'Execution and idempotency', false, sqlstate || ': ' || sqlerrm); end;

  -- ===== Audit and persistence (H1-H4)
  begin
    r := mx.err('update public.aios_audit_events set metadata = ''{}''::jsonb where id = (select id from public.aios_audit_events limit 1)');
    r2 := mx.err('delete from public.aios_audit_events where id = (select id from public.aios_audit_events limit 1)');
    perform mx.rec('H1', 'Audit and persistence', r = '42501' and r2 = '42501', 'audit ledger update=' || r || ', delete=' || r2);
  exception when others then perform mx.rec('H1', 'Audit and persistence', false, sqlstate || ': ' || sqlerrm); end;
  begin
    v := mx.u('f6');
    perform mx.rec('H2', 'Audit and persistence',
      exists (select 1 from public.aios_audit_events where invocation_id = v and event_type = 'tool_invocation_requested')
      and (select count(*) from public.aios_audit_events where invocation_id = v) >= 3, 'request and state changes are audited');
  exception when others then perform mx.rec('H2', 'Audit and persistence', false, sqlstate || ': ' || sqlerrm); end;
  begin
    perform mx.rec('H3', 'Audit and persistence',
      exists (select 1 from public.aios_audit_events where invocation_id = mx.u('g3') and new_state = 'failed')
      and exists (select 1 from public.aios_audit_events where invocation_id = mx.u('f5') and new_state = 'denied'), 'failure and denial are recorded');
  exception when others then perform mx.rec('H3', 'Audit and persistence', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.q('service_role', null, format('select (public.verify_audit_chain(%L))->>''valid''', A), 'service_role');
    r2 := mx.q('service_role', null, format('select (public.verify_audit_chain(%L))->>''valid''', B), 'service_role');
    perform mx.rec('H4', 'Audit and persistence',
      r = 'true' and r2 = 'true'
      and not exists (select 1 from public.aios_approvals ap join public.aios_tool_invocations i on i.id = ap.invocation_id where ap.status = 'approved' and i.status in ('requires_approval', 'denied', 'expired')),
      'audit chains valid (A=' || r || ', B=' || r2 || ') and approved approvals match invocation state');
  exception when others then perform mx.rec('H4', 'Audit and persistence', false, sqlstate || ': ' || sqlerrm); end;

  -- ===== Security and permissions (I1-I4)
  begin
    r := mx.dml('authenticated', outu, format('insert into public.aios_approvals (organization_id, action, risk_level, status) values (%L, ''x'', ''low'', ''approved'')', A));
    perform mx.rec('I1', 'Security and permissions', mx.hidden(outu, 'aios_approvals', A) and r like 'ERR:%', 'RLS: outsider reads nothing, direct approval insert=' || r);
  exception when others then perform mx.rec('I1', 'Security and permissions', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.q('authenticated', adm, 'select private.aios_expire_stale_approvals()::text');
    r2 := mx.q('authenticated', adm, format('select private.aios_resolve_approval(%L, ''approved'', %L, ''x'')::text', mx.apr(mx.u('f1')), adm));
    perform mx.rec('I2', 'Security and permissions', r = 'ERR:42501' and r2 = 'ERR:42501', 'private functions refused to authenticated: ' || r || ' / ' || r2);
  exception when others then perform mx.rec('I2', 'Security and permissions', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.q('anon', null, format('select count(*) from public.aios_tasks where organization_id = %L', A));
    r2 := mx.q('anon', null, format('select public.aios_resolve_approval(%L, ''approved'', %L, ''x'')::text', mx.apr(mx.u('f1')), adm));
    perform mx.rec('I3', 'Security and permissions', r in ('0', 'ERR:42501') and r2 = 'ERR:42501', 'anonymous: read=' || r || ', approval RPC=' || r2);
  exception when others then perform mx.rec('I3', 'Security and permissions', false, sqlstate || ': ' || sqlerrm); end;
  begin
    r := mx.dml('authenticated', mem, format('update public.aios_organization_members set role = ''owner'' where organization_id = %L and user_id = %L', A, mem));
    perform mx.rec('I4', 'Security and permissions',
      (select role from public.aios_organization_members where organization_id = A and user_id = mem) = 'member', 'self-escalation attempt (' || r || ') left role unchanged');
  exception when others then perform mx.rec('I4', 'Security and permissions', false, sqlstate || ': ' || sqlerrm); end;
end $$;

-- ------------------------------------------------------------------ summary
select domain, count(*) as cases, count(*) filter (where ok) as passed from mx.results group by domain order by min(seq);
do $$
declare n int; bad text;
begin
  select count(*), string_agg(id || ' [' || coalesce(detail, '') || ']', E'\n') filter (where not ok) into n, bad from mx.results;
  if bad is not null then raise exception E'matrix failures:\n%', bad; end if;
  if n <> 45 then raise exception 'expected 45 SQL cases (G4 runs in the concurrency job), got %', n; end if;
end $$;
rollback;
select 'ok: certification matrix (45 SQL cases; G4 in concurrency job)' as result;
