-- Regression: approval expiry is mandatory (NULL-expiry gap closure) and authorization fails closed on it.
-- Covers: NULL-expiry insert (defaulted), NULL-expiry update (rejected), NULL-expiry approved row (authorization rejects),
-- expired approval, resolved-approval immutability, contract-version mismatch, and janitor convergence of a legacy NULL row.
-- Harness and world fixtures are copied from 05_certification_matrix.sql. Runs inside one transaction that is rolled back.
-- Legacy-shaped rows (NULL expiry on a resolved approval) use session_replication_role = replica for that single statement only,
-- then the role is reset to origin before authorization runs, so every trigger executes as in production.
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


select mx.put('a_np', mx.agent(mx.u('orgA'), 'mx-np', 'idle', 'medium', '["support.export_customer_data"]', '{}', true)::text);

do $$
declare
  A uuid := mx.u('orgA'); req uuid := mx.u('u_req'); adm uuid := mx.u('u_adm');
  x text := '{"format":"csv","scope":"all"}';
  v uuid; ap uuid; r text; r2 text; e timestamptz; ap2 uuid;
begin
  -- N1: a pending approval inserted with NULL expiry receives a mandatory expiry (~24h).
  begin
    perform mx.reset_ctx();
    insert into public.aios_approvals (organization_id, action, risk_level, status, expires_at)
      values (A, 'n1', 'low', 'pending', null) returning id, expires_at into ap2, e;
    perform mx.rec('N1', 'Mandatory expiry', e is not null and e > now() + interval '23 hours' and e < now() + interval '25 hours', 'defaulted expiry=' || coalesce(e::text, 'NULL'));
  exception when others then perform mx.rec('N1', 'Mandatory expiry', false, sqlstate || ': ' || sqlerrm); end;

  -- N2: clearing the expiry of a pending approval is rejected.
  begin
    r := mx.err(format('update public.aios_approvals set expires_at = null where id = %L', ap2));
    perform mx.rec('N2', 'Mandatory expiry', r = '23514' and (select expires_at is not null from public.aios_approvals where id = ap2), 'NULLing a pending expiry: ' || r);
  exception when others then perform mx.rec('N2', 'Mandatory expiry', false, sqlstate || ': ' || sqlerrm); end;

  -- N3: an approved approval with NULL expiry (legacy shape) can never authorize execution.
  begin
    v := mx.inv('n3', A, mx.u('a_np'), 'support.export_customer_data', x::jsonb, req); ap := mx.apr(v);
    r := mx.resolve(ap, 'approved', adm);
    set local session_replication_role = replica;
    update public.aios_approvals set expires_at = null where id = ap;
    set local session_replication_role = origin;
    perform mx.rec('N3', 'Mandatory expiry', r = 'OK' and mx.authz(v) like '42501|valid approval required%' and mx.st(v) = 'approved', 'NULL-expiry approved row: ' || mx.authz(v) || ', invocation=' || mx.st(v));
  exception when others then set local session_replication_role = origin; perform mx.rec('N3', 'Mandatory expiry', false, sqlstate || ': ' || sqlerrm); end;

  -- N4: an expired approved approval is rejected at authorization.
  begin
    v := mx.inv('n4', A, mx.u('a_np'), 'support.export_customer_data', x::jsonb, req); ap := mx.apr(v);
    r := mx.resolve(ap, 'approved', adm);
    set local session_replication_role = replica;
    update public.aios_approvals set expires_at = now() - interval '1 minute' where id = ap;
    set local session_replication_role = origin;
    perform mx.rec('N4', 'Mandatory expiry', r = 'OK' and mx.authz(v) like '42501|valid approval required%' and mx.st(v) = 'approved', 'expired approved row: ' || mx.authz(v));
  exception when others then set local session_replication_role = origin; perform mx.rec('N4', 'Mandatory expiry', false, sqlstate || ': ' || sqlerrm); end;

  -- N5: a resolved approval's expiry cannot be rewritten (no revival of a lapsed approval by direct SQL).
  begin
    v := mx.inv('n5', A, mx.u('a_np'), 'support.export_customer_data', x::jsonb, req); ap := mx.apr(v);
    r := mx.resolve(ap, 'approved', adm);
    perform mx.rec('N5', 'Mandatory expiry', r = 'OK' and mx.err(format('update public.aios_approvals set expires_at = now() + interval ''30 days'' where id = %L', ap)) = '42501', 'resolved approval is immutable');
  exception when others then perform mx.rec('N5', 'Mandatory expiry', false, sqlstate || ': ' || sqlerrm); end;

  -- N6: contract version change after approval invalidates the approved approval.
  begin
    v := mx.inv('n6', A, mx.u('a_np'), 'support.export_customer_data', x::jsonb, req); ap := mx.apr(v);
    r := mx.resolve(ap, 'approved', adm);
    update public.aios_contracts set is_active = false where agent_id = mx.u('a_np');
    insert into public.aios_contracts (organization_id, agent_id, version, risk_level, allowed_tools, limits, is_active)
      values (A, mx.u('a_np'), 2, 'medium', '["support.export_customer_data"]', '{}', true);
    r2 := mx.authz(v);
    perform mx.rec('N6', 'Mandatory expiry', r = 'OK' and r2 not like 'OK%' and mx.st(v) <> 'executing', 'contract version mismatch: ' || r2 || ', invocation=' || mx.st(v));
  exception when others then perform mx.rec('N6', 'Mandatory expiry', false, sqlstate || ': ' || sqlerrm); end;

  -- N7: janitor still converges a legacy pending NULL-expiry row (>24h) via the creation-time fallback.
  begin
    set local session_replication_role = replica;
    insert into public.aios_approvals (id, organization_id, action, risk_level, status, expires_at, created_at)
      values ('d7d7d7d7-0000-4000-8000-000000000007', A, 'n7', 'low', 'pending', null, now() - interval '3 days');
    set local session_replication_role = origin;
    perform private.aios_expire_stale_approvals();
    perform mx.rec('N7', 'Mandatory expiry', (select status from public.aios_approvals where id = 'd7d7d7d7-0000-4000-8000-000000000007') = 'expired', 'legacy NULL-expiry row converged');
  exception when others then set local session_replication_role = origin; perform mx.rec('N7', 'Mandatory expiry', false, sqlstate || ': ' || sqlerrm); end;
end $$;

select 'N_RESULT|' || id || '|' || case when ok then 'PASS' else 'FAIL' end || '|' || replace(coalesce(detail, ''), E'\n', ' ') from mx.results order by seq;
do $$
declare n int; bad text;
begin
  select count(*), string_agg(id || ' [' || coalesce(detail, '') || ']', E'\n') filter (where not ok) into n, bad from mx.results;
  if bad is not null then raise exception E'expiry regression failures:\n%', bad; end if;
  if n <> 7 then raise exception 'expected 7 cases, got %', n; end if;
end $$;
rollback;
select 'ok: approval mandatory-expiry regression (7 cases)' as result;
