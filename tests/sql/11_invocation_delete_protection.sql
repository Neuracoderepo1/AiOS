-- ET27 follow-up: invocation DELETE protection. Real database behaviour only (real triggers, real roles, real JWT claims).
-- One transaction, rolled back. Harness (mx.*) is copied from 10_invocation_seal_guard.sql and left unmodified there.
-- Covers: audited and unaudited rows in every lifecycle state, deleted by authenticated / anon / service_role / table owner,
-- bulk and cascade deletes, audit-ledger referential integrity (including with the delete guard bypassed), guard metadata,
-- and in-database mutation testing of the guard (a surviving mutant fails this file).
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
  ('00000000-0000-4000-8000-000000002001', 'authenticated', 'authenticated', 'sg-req@example.test'),
  ('00000000-0000-4000-8000-000000002002', 'authenticated', 'authenticated', 'sg-req2@example.test');
select mx.put('u_req', '00000000-0000-4000-8000-000000002001'), mx.put('u_req2', '00000000-0000-4000-8000-000000002002'),
       mx.put('orgA', 'a3a3a3a3-0000-4000-8000-000000000001'), mx.put('orgB', 'b4b4b4b4-0000-4000-8000-000000000002');
insert into public.aios_organizations (id, name) values (mx.u('orgA'), 'sg-org-a'), (mx.u('orgB'), 'sg-org-b');
select mx.put('a1',    mx.agent(mx.u('orgA'), 'sg-a1',  'idle',      'medium', '["support.search_tickets","support.export_customer_data"]', '{}', true)::text),
       mx.put('a2',    mx.agent(mx.u('orgA'), 'sg-a2',  'idle',      'medium', '["support.search_tickets"]', '{}', true)::text),
       mx.put('a_sus', mx.agent(mx.u('orgA'), 'sg-sus', 'suspended', 'medium', '["support.search_tickets"]', '{}', true)::text);
insert into public.aios_tasks (id, organization_id, title) values
  ('c5c5c5c5-0000-4000-8000-00000000000a', mx.u('orgA'), 'sg task a'), ('c5c5c5c5-0000-4000-8000-00000000000b', mx.u('orgA'), 'sg task b');
select mx.put('taskA', 'c5c5c5c5-0000-4000-8000-00000000000a'), mx.put('taskB', 'c5c5c5c5-0000-4000-8000-00000000000b');
-- an approval id that really exists (export tool requires approval) so approval_id attacks are not stopped by the FK
select mx.put('apr_any', mx.apr(mx.mk_inv(mx.u('orgA'), mx.u('a1'), 'support.export_customer_data', '{"format":"csv","scope":"all"}'::jsonb, mx.u('u_req')))::text);

-- ------------------------------------------------------------------ helpers
create function mx.svc(p_sql text) returns text language sql as $$ select mx.dml('service_role', null, p_sql) $$;
create function mx.snap(p_inv uuid) returns jsonb language sql as $$ select to_jsonb(i) from public.aios_tool_invocations i where i.id = p_inv $$;
-- Run an UPDATE as service_role. Returns '<OK|ERR:state>|<row unchanged true|false>'.
create function mx.attack(p_inv uuid, p_set text) returns text language plpgsql as $$
declare b jsonb := mx.snap(p_inv); r text;
begin
  r := mx.svc(format('update public.aios_tool_invocations set %s where id = %L', p_set, p_inv));
  return r || '|' || (b = mx.snap(p_inv))::text;
end $$;
create function mx.mk_exec() returns uuid language plpgsql as $$
declare v uuid := mx.mk_inv(mx.u('orgA'), mx.u('a1'), 'support.search_tickets', '{"limit":5}'::jsonb, mx.u('u_req')); r text;
begin r := mx.authz(v); if r <> 'OK' or mx.st(v) <> 'executing' then raise exception 'fixture: could not reach executing (%, %)', r, mx.st(v); end if; return v; end $$;
create function mx.rec2(p_label text, p_id text, p_ok boolean, p_detail text) returns void language sql as
$$ select mx.rec(p_label || ':' || p_id, p_label, p_ok, p_detail) $$;

-- ------------------------------------------------------------------ delete-protection helpers
create function mx.u_text(p_k text) returns text language sql stable as $$ select v from mx.w where k = p_k $$;
create function mx.row_exists(p uuid) returns boolean language sql as $$ select exists (select 1 from public.aios_tool_invocations where id = p) $$;
-- Run a statement as the database owner, then force deferred constraints. Returns the sqlstate raised, or 'NONE'.
create function mx.owner_stmt(p_sql text) returns text language plpgsql as $$
declare st text;
begin
  perform mx.reset_ctx();
  begin
    execute p_sql;
    set constraints all immediate;
  exception when others then get stacked diagnostics st = returned_sqlstate; return st; end;
  return 'NONE';
end $$;

-- ------------------------------------------------------------------ the battery
create function mx.dbattery(p_label text) returns int language plpgsql as $$
declare
  res text := '{"tickets":[],"count":0,"summary":"ok"}';
  aud uuid; e uuid; s uuid; f uuid; d uuid; c uuid; z uuid; q uuid; ur uuid; ue uuid;
  targets uuid[]; names text[] := array['pre-execution (audited)','executing (audited)','succeeded','failed','denied','cancelled','expired','requires_approval','pre-execution (UNAUDITED)','executing (UNAUDITED)'];
  audtrgs text[]; trg text; i int; r text; en "char"; ty int; guard_found boolean;
  n_inv bigint; n_aud bigint; ok boolean;
begin
  perform mx.reset_ctx();
  -- audited fixtures, all triggers ON, through the real kernel
  aud := mx.mk_inv(mx.u('orgA'), mx.u('a1'), 'support.search_tickets', '{"limit":5}'::jsonb, mx.u('u_req'));
  e   := mx.mk_exec();
  s   := mx.mk_exec(); perform mx.svc(format($q$update public.aios_tool_invocations set status='succeeded', result=%L::jsonb, result_hash='hash-orig', completed_at=now() where id=%L$q$, res, s));
  f   := mx.mk_exec(); perform mx.svc(format($q$update public.aios_tool_invocations set status='failed', error_code='E_ORIG', error_message='orig', completed_at=now() where id=%L$q$, f));
  d   := mx.mk_inv(mx.u('orgA'), mx.u('a_sus'), 'support.search_tickets', '{"limit":5}'::jsonb, mx.u('u_req'));
  c   := mx.mk_exec(); perform mx.svc(format($q$update public.aios_tool_invocations set status='cancelled', error_code='E_CANC', error_message='orig', completed_at=now() where id=%L$q$, c));
  z   := mx.mk_exec(); perform mx.svc(format($q$update public.aios_tool_invocations set status='expired', error_code='E_EXP', error_message='orig', completed_at=now() where id=%L$q$, z));
  q   := mx.mk_inv(mx.u('orgA'), mx.u('a1'), 'support.export_customer_data', '{"format":"csv","scope":"all"}'::jsonb, mx.u('u_req'));
  -- UNAUDITED fixtures: only the audit-writing trigger(s) are switched off while the rows are created (owner, fixture only).
  select coalesce(array_agg(t.tgname), '{}') into audtrgs from pg_trigger t join pg_proc p on p.oid = t.tgfoid
   where t.tgrelid = 'public.aios_tool_invocations'::regclass and not t.tgisinternal and t.tgenabled = 'O'
     and p.proname in ('aios_log_invocation', 'aios_log_tool_invocation_audit');
  foreach trg in array audtrgs loop execute format('alter table public.aios_tool_invocations disable trigger %I', trg); end loop;
  ur := mx.mk_inv(mx.u('orgA'), mx.u('a1'), 'support.search_tickets', '{"limit":5}'::jsonb, mx.u('u_req'));
  ue := mx.mk_exec();
  foreach trg in array audtrgs loop execute format('alter table public.aios_tool_invocations enable trigger %I', trg); end loop;
  targets := array[aud, e, s, f, d, c, z, q, ur, ue];

  perform mx.rec2(p_label, 'F1 audit-writing trigger(s) located for the unaudited fixtures', coalesce(array_length(audtrgs, 1), 0) >= 1, array_to_string(audtrgs, ','));
  perform mx.rec2(p_label, 'F2 audited fixtures all have audit rows',
    (select bool_and(exists (select 1 from public.aios_audit_events a where a.invocation_id = x)) from unnest(targets[1:8]) x), null);
  perform mx.rec2(p_label, 'F3 unaudited fixtures have no audit rows',
    not exists (select 1 from public.aios_audit_events a where a.invocation_id in (ur, ue)), null);
  perform mx.rec2(p_label, 'F4 fixture lifecycle states as intended',
    mx.st(e) = 'executing' and mx.st(s) = 'succeeded' and mx.st(f) = 'failed' and mx.st(d) = 'denied' and mx.st(c) = 'cancelled'
    and mx.st(z) = 'expired' and mx.st(q) = 'requires_approval' and mx.st(ue) = 'executing' and mx.st(ur) in ('requested', 'approved'),
    (select string_agg(mx.st(x), ',') from unnest(targets) x));

  -- privilege layer
  perform mx.rec2(p_label, 'P1 service_role has no DELETE privilege', not has_table_privilege('service_role', 'public.aios_tool_invocations', 'DELETE'), null);
  perform mx.rec2(p_label, 'P2 authenticated has no DELETE privilege', not has_table_privilege('authenticated', 'public.aios_tool_invocations', 'DELETE'), null);
  perform mx.rec2(p_label, 'P3 anon has no DELETE privilege', not has_table_privilege('anon', 'public.aios_tool_invocations', 'DELETE'), null);
  perform mx.rec2(p_label, 'P4 no PUBLIC or non-owner grantee holds DELETE',
    not exists (select 1 from pg_class cl cross join lateral aclexplode(cl.relacl) a
                where cl.oid = 'public.aios_tool_invocations'::regclass and a.privilege_type = 'DELETE' and a.grantee <> cl.relowner), null);

  -- trigger layer metadata
  select t.tgenabled, t.tgtype::int into en, ty from pg_trigger t where t.tgrelid = 'public.aios_tool_invocations'::regclass and t.tgname = 'trg_aios_invocation_no_delete';
  guard_found := found;
  perform mx.rec2(p_label, 'G1 delete guard trigger exists, enabled, BEFORE ROW DELETE only', guard_found and en = 'O' and (ty & 11) = 11 and (ty & (4 | 16 | 32 | 64)) = 0, coalesce(en::text, 'missing') || '/' || coalesce(ty::text, '-'));
  perform mx.rec2(p_label, 'G2 guard function is SECURITY DEFINER with empty search_path',
    exists (select 1 from pg_proc where oid = 'private.aios_invocation_no_delete()'::regprocedure and prosecdef and proconfig @> array['search_path=""']), null);
  perform mx.rec2(p_label, 'G3 guard function not executable by client roles',
    not has_function_privilege('anon', 'private.aios_invocation_no_delete()', 'EXECUTE')
    and not has_function_privilege('authenticated', 'private.aios_invocation_no_delete()', 'EXECUTE')
    and not has_function_privilege('service_role', 'private.aios_invocation_no_delete()', 'EXECUTE'), null);

  -- behaviour: every actor x every state x audited/unaudited
  n_inv := (select count(*) from public.aios_tool_invocations);
  n_aud := (select count(*) from public.aios_audit_events);
  for i in 1..array_length(targets, 1) loop
    r := mx.dml('authenticated', mx.u('u_req'), format('delete from public.aios_tool_invocations where id = %L', targets[i]));
    perform mx.rec2(p_label, 'A' || i || ' authenticated cannot delete ' || names[i], r = 'ERR:42501' and mx.row_exists(targets[i]), r);
    r := mx.dml('anon', null, format('delete from public.aios_tool_invocations where id = %L', targets[i]));
    perform mx.rec2(p_label, 'B' || i || ' anon cannot delete ' || names[i], r = 'ERR:42501' and mx.row_exists(targets[i]), r);
    r := mx.dml('service_role', null, format('delete from public.aios_tool_invocations where id = %L', targets[i]));
    perform mx.rec2(p_label, 'C' || i || ' service_role cannot delete ' || names[i], r = 'ERR:42501' and mx.row_exists(targets[i]), r);
    r := mx.owner_stmt(format('delete from public.aios_tool_invocations where id = %L', targets[i]));
    perform mx.rec2(p_label, 'D' || i || ' table owner cannot delete ' || names[i], r = '55000' and mx.row_exists(targets[i]), r);
  end loop;

  -- bulk and indirect deletes
  r := mx.dml('service_role', null, 'delete from public.aios_tool_invocations');
  perform mx.rec2(p_label, 'E1 service_role bulk DELETE refused', r = 'ERR:42501' and (select count(*) from public.aios_tool_invocations) = n_inv, r);
  r := mx.dml('authenticated', mx.u('u_req'), 'delete from public.aios_tool_invocations where true');
  perform mx.rec2(p_label, 'E2 authenticated bulk DELETE refused', r = 'ERR:42501' and (select count(*) from public.aios_tool_invocations) = n_inv, r);
  r := mx.owner_stmt('delete from public.aios_tool_invocations');
  perform mx.rec2(p_label, 'E3 owner bulk DELETE refused', r = '55000' and (select count(*) from public.aios_tool_invocations) = n_inv, r);
  r := mx.owner_stmt(format('delete from public.aios_organizations where id = %L', mx.u('orgA')));
  perform mx.rec2(p_label, 'E4 owner organization delete cannot cascade into the ledgers', r <> 'NONE' and exists (select 1 from public.aios_organizations where id = mx.u('orgA'))
    and (select count(*) from public.aios_tool_invocations) = n_inv, r);
  r := mx.dml('service_role', null, format('delete from public.aios_organizations where id = %L', mx.u('orgA')));
  perform mx.rec2(p_label, 'E5 service_role organization delete cannot cascade into the ledgers', r like 'ERR:%' and exists (select 1 from public.aios_organizations where id = mx.u('orgA'))
    and (select count(*) from public.aios_tool_invocations) = n_inv, r);
  r := mx.owner_stmt('truncate public.aios_tool_invocations');
  perform mx.rec2(p_label, 'E6 owner TRUNCATE still refused', r <> 'NONE' and (select count(*) from public.aios_tool_invocations) = n_inv, r);

  -- audit referential integrity
  perform mx.rec2(p_label, 'R1 audit rows unchanged after every attempt above', (select count(*) from public.aios_audit_events) = n_aud, null);
  perform mx.rec2(p_label, 'R2 audit->invocation FK present, NO ACTION, deferrable',
    exists (select 1 from pg_constraint where conname = 'aios_audit_events_invocation_id_fkey' and conrelid = 'public.aios_audit_events'::regclass
            and confrelid = 'public.aios_tool_invocations'::regclass and confdeltype = 'a' and condeferrable), null);
  r := mx.dml('service_role', null, format('delete from public.aios_audit_events where invocation_id = %L', aud));
  perform mx.rec2(p_label, 'R3 service_role cannot delete audit rows of an invocation', r like 'ERR:%' and (select count(*) from public.aios_audit_events) = n_aud, r);
  r := mx.owner_stmt(format('delete from public.aios_audit_events where invocation_id = %L', aud));
  perform mx.rec2(p_label, 'R4 owner cannot delete audit rows of an invocation', r <> 'NONE' and (select count(*) from public.aios_audit_events) = n_aud, r);
  -- defence in depth: with the delete guard bypassed, the FK still protects an AUDITED invocation (the guard is the only barrier for unaudited rows)
  if guard_found and en = 'O' then execute 'alter table public.aios_tool_invocations disable trigger trg_aios_invocation_no_delete'; end if;
  r := mx.owner_stmt(format('delete from public.aios_tool_invocations where id = %L', aud));
  if guard_found and en = 'O' then execute 'alter table public.aios_tool_invocations enable trigger trg_aios_invocation_no_delete'; end if;
  perform mx.rec2(p_label, 'R5 audit FK alone refuses deletion of an audited invocation (guard bypassed)', r = '23503' and mx.row_exists(aud), r);
  perform mx.rec2(p_label, 'R6 attempts left the invocation count unchanged', (select count(*) from public.aios_tool_invocations) = n_inv, null);

  -- legitimate internal operations remain functional (kernel authorization and lifecycle writes still work)
  r := mx.svc(format($q$update public.aios_tool_invocations set retry_count = retry_count + 1 where id = %L$q$, s));
  perform mx.rec2(p_label, 'L1 service_role operational update (retry_count) still allowed on a sealed row', r = 'OK', r);
  perform mx.rec2(p_label, 'L2 kernel authorization and executing->terminal writes worked while building the fixtures', mx.st(e) = 'executing' and mx.st(s) = 'succeeded', null);
  return (select count(*)::int from mx.results where domain = p_label and not ok);
end $$;

-- ------------------------------------------------------------------ mutation helper
create function mx.dmut(p_name text, p_do text[], p_undo text[]) returns void language plpgsql as $$
declare n int; stmt text;
begin
  foreach stmt in array p_do loop execute stmt; end loop;
  n := mx.dbattery('mut:' || p_name);
  foreach stmt in array p_undo loop execute stmt; end loop;
  perform mx.rec('MUT:' || p_name, 'Mutation', n > 0, case when n > 0 then 'detected by ' || n || ' failing checks' else 'SURVIVED' end);
end $$;

do $$
declare
  n int; def text; trg_orig text :=
    'create trigger trg_aios_invocation_no_delete before delete on public.aios_tool_invocations for each row execute function private.aios_invocation_no_delete()';
  raise_stmt text := 'raise exception ''invocation ledger is append-only: DELETE refused'' using errcode = ''55000'';';
begin
  def := pg_get_functiondef('private.aios_invocation_no_delete()'::regprocedure);
  if position(raise_stmt in def) = 0 then raise exception 'mutation target not found in guard function: %', def; end if;

  n := mx.dbattery('baseline');
  perform mx.rec('BASE-delete', 'Baseline', n = 0, n || ' failing checks with the guard and privileges as shipped');

  perform mx.dmut('guard-function-allows-delete', array[replace(def, raise_stmt, 'return old;')], array[def]);
  perform mx.dmut('guard-function-silently-skips', array[replace(def, raise_stmt, 'return null;')], array[def]);
  perform mx.dmut('trigger-dropped', array['drop trigger trg_aios_invocation_no_delete on public.aios_tool_invocations'], array[trg_orig]);
  perform mx.dmut('trigger-disabled', array['alter table public.aios_tool_invocations disable trigger trg_aios_invocation_no_delete'],
                  array['alter table public.aios_tool_invocations enable trigger trg_aios_invocation_no_delete']);
  perform mx.dmut('trigger-narrowed-by-when-clause',
                  array['drop trigger trg_aios_invocation_no_delete on public.aios_tool_invocations',
                        'create trigger trg_aios_invocation_no_delete before delete on public.aios_tool_invocations for each row when (old.status is null) execute function private.aios_invocation_no_delete()'],
                  array['drop trigger trg_aios_invocation_no_delete on public.aios_tool_invocations', trg_orig]);
  perform mx.dmut('trigger-made-update-only',
                  array['drop trigger trg_aios_invocation_no_delete on public.aios_tool_invocations',
                        'create trigger trg_aios_invocation_no_delete before update on public.aios_tool_invocations for each row execute function private.aios_invocation_no_delete()'],
                  array['drop trigger trg_aios_invocation_no_delete on public.aios_tool_invocations', trg_orig]);
  perform mx.dmut('delete-regranted-to-service_role', array['grant delete on public.aios_tool_invocations to service_role'], array['revoke delete on public.aios_tool_invocations from service_role']);
  perform mx.dmut('delete-regranted-to-authenticated', array['grant delete on public.aios_tool_invocations to authenticated'], array['revoke delete on public.aios_tool_invocations from authenticated']);
  perform mx.dmut('delete-regranted-to-anon', array['grant delete on public.aios_tool_invocations to anon'], array['revoke delete on public.aios_tool_invocations from anon']);
  perform mx.dmut('delete-regranted-to-public', array['grant delete on public.aios_tool_invocations to public'], array['revoke delete on public.aios_tool_invocations from public']);
  perform mx.dmut('guard-function-made-executable-by-service_role', array['grant execute on function private.aios_invocation_no_delete() to service_role'], array['revoke execute on function private.aios_invocation_no_delete() from service_role']);
end $$;

-- ------------------------------------------------------------------ evidence + verdict
select 'ET27D_RESULT|' || domain || '|' || id || '|' || case when ok then 'PASS' else 'FAIL' end || '|' || replace(coalesce(detail, ''), E'\n', ' ') from mx.results where domain not like 'mut:%' order by seq;
select 'ET27D_SUMMARY|checks=' || count(*) filter (where domain not like 'mut:%' and domain <> 'Mutation') || '|checks_failed=' || count(*) filter (where not ok and domain not like 'mut:%' and domain <> 'Mutation')
       || '|mutants=' || count(*) filter (where domain = 'Mutation') || '|mutants_detected=' || count(*) filter (where domain = 'Mutation' and ok)
       || '|mutants_survived=' || count(*) filter (where domain = 'Mutation' and not ok) from mx.results;
select 'ET27D_MUTANT|' || id || '|' || case when ok then 'DETECTED' else 'SURVIVED' end || '|' || detail from mx.results where domain = 'Mutation' order by seq;
do $$
declare bad text;
begin
  select string_agg(id || ' [' || coalesce(detail, '') || ']', E'\n') into bad from mx.results where not ok and domain not like 'mut:%';
  if bad is not null then raise exception E'invocation delete protection checks failed:\n%', bad; end if;
end $$;
rollback;
select 'ok: invocation delete protection (privileges, trigger, audit integrity, mutation)' as result;
