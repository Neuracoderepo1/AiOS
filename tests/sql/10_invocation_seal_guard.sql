-- ET27 / G3: invocation seal guard. Adversarial regression, schema coverage, privilege checks and in-database mutation testing.
-- Real database behaviour only: real triggers, real roles (service_role / authenticated) and real JWT claims; nothing is mocked.
-- Runs in one transaction that is rolled back. Harness (mx.*) is copied from 05_certification_matrix.sql.
--
-- Battery modes:
--   normal   : every trigger on aios_tool_invocations is enabled (production behaviour).
--   isolated : after fixtures are built, the OTHER BEFORE UPDATE triggers are disabled so the seal guard is the only barrier.
--              This is what lets the mutation run prove each column is protected BY THE SEAL GUARD and not only by an older trigger.
-- Mutation testing: the guard function is rewritten in place (column un-frozen, branch disabled, trigger narrowed or dropped) and the
-- isolated battery must fail for every mutant. A surviving mutant fails this file.
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

-- Columns and their classification. frozen-at-terminal columns are every column except retry_count.
create function mx.attacks() returns jsonb language sql as $$ select jsonb_build_array(
  jsonb_build_array('organization_id', format('organization_id = %L', mx.u('orgB'))),
  jsonb_build_array('agent_id',        format('agent_id = %L', mx.u('a2'))),
  jsonb_build_array('task_id',         format('task_id = %L', mx.u('taskB'))),
  jsonb_build_array('tool_key',        $q$tool_key = 'tamper.tool'$q$),
  jsonb_build_array('tool_name',       $q$tool_name = 'tamper.tool'$q$),
  jsonb_build_array('arguments',       $q$arguments = '{"limit":6}'::jsonb$q$),
  jsonb_build_array('arguments_hash',  $q$arguments_hash = repeat('0', 64)$q$),
  jsonb_build_array('authorization_version', 'authorization_version = 99'),
  jsonb_build_array('idempotency_key', $q$idempotency_key = 'tamper-' || gen_random_uuid()::text$q$),
  jsonb_build_array('request_id',      'request_id = gen_random_uuid()'),
  jsonb_build_array('requested_by',    format('requested_by = %L', mx.u('u_req2'))),
  jsonb_build_array('risk_level',      $q$risk_level = 'critical'$q$),
  jsonb_build_array('approval_id',     format('approval_id = %L', mx.u('apr_any'))),
  jsonb_build_array('status',          $q$status = 'cancelled'$q$),
  jsonb_build_array('result',          $q$result = '{"tickets":[],"count":9,"summary":"forged"}'::jsonb$q$),
  jsonb_build_array('result_hash',     $q$result_hash = 'forged'$q$),
  jsonb_build_array('error_code',      $q$error_code = 'FORGED'$q$),
  jsonb_build_array('error_message',   $q$error_message = 'forged'$q$),
  jsonb_build_array('started_at',      $q$started_at = now() + interval '1 day'$q$),
  jsonb_build_array('evaluated_at',    $q$evaluated_at = now() + interval '1 day'$q$),
  jsonb_build_array('completed_at',    $q$completed_at = now() + interval '1 day'$q$),
  jsonb_build_array('created_at',      $q$created_at = now() + interval '1 day'$q$),
  jsonb_build_array('id',              'id = gen_random_uuid()')
) $$;

-- The full adversarial battery. Returns the number of failed checks for this label.
create function mx.battery(p_label text, p_isolated boolean) returns int language plpgsql as $$
declare
  res text := '{"tickets":[],"count":0,"summary":"ok"}';
  e uuid; s uuid; f uuid; d uuid; c uuid; z uuid; q uuid; p1 uuid; p2 uuid;
  a jsonb; r text; k text; st text; skip_exec text[] := array['status','result','result_hash','error_code','error_message','completed_at'];
  trg text; n0 bigint; n1 bigint; blocked boolean;
begin
  -- fixtures, all triggers ON, through the real kernel
  e  := mx.mk_exec();
  s  := mx.mk_exec(); perform mx.svc(format($q$update public.aios_tool_invocations set status='succeeded', result=%L::jsonb, result_hash='hash-orig', completed_at=now() where id=%L$q$, res, s));
  f  := mx.mk_exec(); perform mx.svc(format($q$update public.aios_tool_invocations set status='failed', error_code='E_ORIG', error_message='orig', completed_at=now() where id=%L$q$, f));
  d  := mx.mk_inv(mx.u('orgA'), mx.u('a_sus'), 'support.search_tickets', '{"limit":5}'::jsonb, mx.u('u_req'));
  c  := mx.mk_exec(); perform mx.svc(format($q$update public.aios_tool_invocations set status='cancelled', error_code='E_CANC', error_message='orig', completed_at=now() where id=%L$q$, c));
  z  := mx.mk_exec(); perform mx.svc(format($q$update public.aios_tool_invocations set status='expired', error_code='E_EXP', error_message='orig', completed_at=now() where id=%L$q$, z));
  q  := mx.mk_inv(mx.u('orgA'), mx.u('a1'), 'support.export_customer_data', '{"format":"csv","scope":"all"}'::jsonb, mx.u('u_req'));
  if mx.st(s) <> 'succeeded' or mx.st(f) <> 'failed' or mx.st(d) <> 'denied' or mx.st(c) <> 'cancelled' or mx.st(z) <> 'expired' or mx.st(q) <> 'requires_approval' then
    raise exception 'fixture states wrong: s=% f=% d=% c=% z=% q=%', mx.st(s), mx.st(f), mx.st(d), mx.st(c), mx.st(z), mx.st(q);
  end if;

  if p_isolated then
    set constraints all immediate;
    foreach trg in array array['trg_aios_invocation_status_guard','trg_aios_validate_invocation_integrity','trg_aios_validate_invocation_registry',
                               'trg_aios_validate_tool_result_registry','trg_validate_agent_org','trg_validate_task_org'] loop
      execute format('alter table public.aios_tool_invocations disable trigger %I', trg);
    end loop;
  end if;

  -- 1-3. legitimate transitions remain valid (run in both modes on fresh executing rows)
  p1 := mx.mk_exec(); p2 := mx.mk_exec();
  r := mx.svc(format($q$update public.aios_tool_invocations set status='succeeded', result=%L::jsonb, result_hash='h', completed_at=now() where id=%L$q$, res, p1));
  perform mx.rec2(p_label, 'L1 executing->succeeded valid', r = 'OK' and mx.st(p1) = 'succeeded', r);
  r := mx.svc(format($q$update public.aios_tool_invocations set status='failed', error_code='E', error_message='m', completed_at=now() where id=%L$q$, p2));
  perform mx.rec2(p_label, 'L2 executing->failed valid', r = 'OK' and mx.st(p2) = 'failed', r);
  perform mx.rec2(p_label, 'L3 kernel denial (pre-execution) valid', mx.st(d) = 'denied', mx.st(d));
  if not p_isolated then
    -- executing -> denied is not a supported transition (status_guard); denial happens before execution
    r := mx.attack(e, $q$status = 'denied'$q$);
    perform mx.rec2(p_label, 'L3b executing->denied rejected (unsupported)', r like 'ERR:%|true', r);
  end if;

  -- 4-11. every column of every terminal state, through service_role
  for a in select value from jsonb_array_elements(mx.attacks()) loop
    k := a->>0;
    foreach st in array array['succeeded','failed','denied','cancelled','expired'] loop
      r := mx.attack(case st when 'succeeded' then s when 'failed' then f when 'denied' then d when 'cancelled' then c else z end, a->>1);
      perform mx.rec2(p_label, 'T ' || st || ' rewrite ' || k || ' rejected', r like 'ERR:%|true', r);
    end loop;
    if not (k = any (skip_exec)) then
      r := mx.attack(e, a->>1);
      perform mx.rec2(p_label, 'X executing rewrite ' || k || ' rejected', r like 'ERR:%|true', r);
    end if;
  end loop;

  -- pre-execution rows keep their lifecycle, but identity and creation time never change
  foreach k in array array['created_at','id'] loop
    r := mx.attack(q, (select x->>1 from jsonb_array_elements(mx.attacks()) x where x->>0 = k));
    perform mx.rec2(p_label, 'P pre-execution rewrite ' || k || ' rejected', r like 'ERR:%|true', r);
  end loop;

  -- operational metadata and benign writes stay possible; combined writes cannot launder an outcome change
  r := mx.svc(format('update public.aios_tool_invocations set retry_count = retry_count + 1 where id = %L', s));
  perform mx.rec2(p_label, 'M1 retry_count on sealed row allowed', r = 'OK', r);
  r := mx.svc(format('update public.aios_tool_invocations set result = result, status = status where id = %L', s));
  perform mx.rec2(p_label, 'M2 no-op update on sealed row allowed', r = 'OK', r);
  r := mx.attack(s, $q$retry_count = retry_count + 1, result_hash = 'laundered'$q$);
  perform mx.rec2(p_label, 'M3 retry_count cannot launder a result_hash rewrite', r like 'ERR:%|true', r);
  r := mx.svc(format('update public.aios_tool_invocations set retry_count = retry_count + 1 where id = %L', e));
  perform mx.rec2(p_label, 'M4 retry_count on executing row allowed', r = 'OK' and mx.st(e) = 'executing', r);

  -- 12. other roles cannot write at all
  r := mx.dml('authenticated', mx.u('u_req'), format($q$update public.aios_tool_invocations set result_hash = 'x' where id = %L$q$, s));
  perform mx.rec2(p_label, 'R1 authenticated cannot update sealed outcome', r like 'ERR:%' and mx.snap(s)->>'result_hash' = 'hash-orig', r);

  -- 14. DELETE / TRUNCATE against existing controls
  select count(*) into n0 from public.aios_tool_invocations;
  r := mx.svc('truncate public.aios_tool_invocations');
  perform mx.rec2(p_label, 'D1 service_role TRUNCATE refused', r like 'ERR:%' and (select count(*) from public.aios_tool_invocations) = n0, r);
  r := mx.svc('truncate public.aios_tool_invocations cascade');
  perform mx.rec2(p_label, 'D2 service_role TRUNCATE CASCADE refused', r like 'ERR:%' and (select count(*) from public.aios_tool_invocations) = n0, r);
  r := mx.err('truncate public.aios_tool_invocations');
  perform mx.rec2(p_label, 'D3 owner TRUNCATE refused', r <> 'NONE' and (select count(*) from public.aios_tool_invocations) = n0, r);
  blocked := false;
  begin
    perform mx.reset_ctx();
    delete from public.aios_tool_invocations where id = s;
    set constraints all immediate;
  exception when others then blocked := true; end;
  perform mx.rec2(p_label, 'D4 DELETE of a sealed, audited invocation cannot complete', blocked and exists (select 1 from public.aios_tool_invocations where id = s), blocked::text);

  if p_isolated then
    foreach trg in array array['trg_aios_invocation_status_guard','trg_aios_validate_invocation_integrity','trg_aios_validate_invocation_registry',
                               'trg_aios_validate_tool_result_registry','trg_validate_agent_org','trg_validate_task_org'] loop
      execute format('alter table public.aios_tool_invocations enable trigger %I', trg);
    end loop;
  end if;
  return (select count(*)::int from mx.results where domain = p_label and not ok);
end $$;

-- ------------------------------------------------------------------ mutation helpers
create function mx.mutate(p_name text, p_from text, p_to text) returns void language plpgsql as $$
declare def text := mx.u_text('seal_def'); n int;
begin
  if position(p_from in def) = 0 then raise exception 'mutation target not found for %: %', p_name, p_from; end if;
  execute replace(def, p_from, p_to);
  n := mx.battery('mut:' || p_name, true);
  execute def;  -- restore the original guard
  perform mx.rec('MUT:' || p_name, 'Mutation', n > 0, case when n > 0 then 'detected by ' || n || ' failing checks' else 'SURVIVED' end);
end $$;
create function mx.u_text(p_k text) returns text language sql stable as $$ select v from mx.w where k = p_k $$;
create function mx.mutate_trigger(p_name text, p_mutation_sql text) returns void language plpgsql as $$
declare n int;
begin
  execute p_mutation_sql;
  n := mx.battery('mut:' || p_name, true);
  execute 'drop trigger if exists trg_aios_invocation_seal_guard on public.aios_tool_invocations';
  execute 'create trigger trg_aios_invocation_seal_guard before update on public.aios_tool_invocations for each row execute function private.aios_invocation_seal_guard()';
  perform mx.rec('MUT:' || p_name, 'Mutation', n > 0, case when n > 0 then 'detected by ' || n || ' failing checks' else 'SURVIVED' end);
end $$;

-- ------------------------------------------------------------------ schema coverage, privileges, trigger shape
do $$
declare
  expected text[] := array['id','organization_id','agent_id','task_id','tool_name','arguments','status','result','risk_level','approval_id','created_at','completed_at',
    'idempotency_key','tool_key','authorization_version','arguments_hash','result_hash','evaluated_at','started_at','error_code','error_message','retry_count','request_id','requested_by'];
  live text[]; missing text[]; unexpected text[]; c text; tg record; fn record;
begin
  select array_agg(column_name::text order by column_name) into live from information_schema.columns where table_schema = 'public' and table_name = 'aios_tool_invocations';
  select array_agg(x) into missing from unnest(expected) x where x <> all (live);
  select array_agg(x) into unexpected from unnest(live) x where x <> all (expected);
  perform mx.rec('COV1', 'Coverage', unexpected is null, 'live columns not classified by the seal guard coverage list: ' || coalesce(array_to_string(unexpected, ','), 'none'));
  perform mx.rec('COV2', 'Coverage', missing is null, 'classified columns absent from the live table: ' || coalesce(array_to_string(missing, ','), 'none'));
  for c in select unnest(live) loop
    raise notice 'ET27_COVERAGE|%|%', c, case
      when c in ('id','created_at') then 'frozen always'
      when c = 'retry_count' then 'mutable (operational counter)'
      when c in ('status','result','result_hash','error_code','error_message','completed_at') then 'mutable only while executing (the outcome write); frozen once terminal'
      else 'frozen from executing onward' end;
  end loop;

  select * into tg from pg_trigger where tgrelid = 'public.aios_tool_invocations'::regclass and tgname = 'trg_aios_invocation_seal_guard';
  perform mx.rec('TRG1', 'Coverage', tg.oid is not null and tg.tgenabled = 'O', 'seal trigger present and enabled (origin)');
  perform mx.rec('TRG2', 'Coverage', tg.oid is not null and (tg.tgtype & 1) = 1 and (tg.tgtype & 2) = 2 and (tg.tgtype & 16) = 16 and (tg.tgtype & 4) = 0 and (tg.tgtype & 8) = 0
                 and pg_get_triggerdef(tg.oid) not like '%UPDATE OF%', 'BEFORE UPDATE FOR EACH ROW with no column list (no UPDATE OF gap)');
  select * into tg from pg_trigger where tgrelid = 'public.aios_tool_invocations'::regclass and tgname = 'trg_aios_invocation_no_truncate';
  perform mx.rec('TRG3', 'Coverage', tg.oid is not null and tg.tgenabled = 'O' and (tg.tgtype & 32) = 32, 'TRUNCATE guard trigger present and enabled');
  select p.prosecdef, p.proconfig into fn from pg_proc p where p.oid = 'private.aios_invocation_seal_guard()'::regprocedure;
  perform mx.rec('FN1', 'Coverage', fn.prosecdef and exists (select 1 from unnest(fn.proconfig) cfg where cfg in ('search_path=""', 'search_path=')) , 'guard is SECURITY DEFINER with an empty search_path');
  perform mx.rec('FN2', 'Coverage',
    not has_function_privilege('anon', 'private.aios_invocation_seal_guard()', 'execute') and not has_function_privilege('authenticated', 'private.aios_invocation_seal_guard()', 'execute')
    and not has_function_privilege('service_role', 'private.aios_invocation_seal_guard()', 'execute')
    and not has_function_privilege('service_role', 'private.aios_invocation_no_truncate()', 'execute'), 'guard functions are not executable by client roles');
  perform mx.rec('PRIV1', 'Coverage', not has_table_privilege('service_role', 'public.aios_tool_invocations', 'truncate') and not has_table_privilege('authenticated', 'public.aios_tool_invocations', 'truncate'),
                 'TRUNCATE privilege revoked from client roles');
end $$;

-- ------------------------------------------------------------------ run: baseline then mutation
do $$
declare n int; col text;
  term_cols text[] := array['status','result','result_hash','error_code','error_message','completed_at','started_at','evaluated_at','arguments','arguments_hash',
                            'approval_id','tool_key','tool_name','authorization_version','idempotency_key','request_id','requested_by','risk_level','organization_id','agent_id','task_id'];
  exec_cols text[] := array['arguments','arguments_hash','approval_id','tool_key','tool_name','authorization_version','idempotency_key','request_id','requested_by','risk_level',
                            'started_at','evaluated_at','organization_id','agent_id','task_id'];
begin
  perform mx.put('seal_def', pg_get_functiondef('private.aios_invocation_seal_guard()'::regprocedure));
  n := mx.battery('normal', false);
  perform mx.rec('BASE-normal', 'Baseline', n = 0, n || ' failing checks with every trigger enabled');
  n := mx.battery('isolated', true);
  perform mx.rec('BASE-isolated', 'Baseline', n = 0, n || ' failing checks with the seal guard as the only update barrier');

  foreach col in array term_cols loop
    perform mx.mutate('terminal-unfreeze-' || col, 'array[''retry_count''];', 'array[''retry_count'',''' || col || '''];');
  end loop;
  foreach col in array exec_cols loop
    perform mx.mutate('executing-unfreeze-' || col, 'array[''status'',''result'',', 'array[''' || col || ''',''status'',''result'',');
  end loop;
  perform mx.mutate('terminal-branch-off',    'if old.status = any (v_terminal) then', 'if false then');
  perform mx.mutate('executing-branch-off',   'elsif old.status = ''executing'' then', 'elsif false then');
  perform mx.mutate('comparison-skipped',     'v_old := to_jsonb(old) - v_mut;', 'return new;');
  perform mx.mutate('always-frozen-removed',  'if new.id is distinct from old.id or new.created_at is distinct from old.created_at then', 'if false then');
  perform mx.mutate('terminal-set-lacks-succeeded', '''succeeded'',', '');
  perform mx.mutate('terminal-set-lacks-failed',    '''failed'',''denied''', '''denied''');
  perform mx.mutate('terminal-set-lacks-denied',    '''denied'',''cancelled''', '''cancelled''');
  perform mx.mutate('terminal-set-lacks-cancelled', '''cancelled'',''expired''', '''expired''');
  perform mx.mutate('terminal-set-lacks-expired',   ',''expired'']', ']');
  perform mx.mutate_trigger('trigger-dropped', 'drop trigger trg_aios_invocation_seal_guard on public.aios_tool_invocations');
  perform mx.mutate_trigger('trigger-narrowed-to-status-result', 'drop trigger trg_aios_invocation_seal_guard on public.aios_tool_invocations; create trigger trg_aios_invocation_seal_guard before update of status, result on public.aios_tool_invocations for each row execute function private.aios_invocation_seal_guard()');
  perform mx.mutate_trigger('trigger-disabled', 'alter table public.aios_tool_invocations disable trigger trg_aios_invocation_seal_guard');
end $$;

-- ------------------------------------------------------------------ evidence + verdict
select 'ET27_RESULT|' || domain || '|' || id || '|' || case when ok then 'PASS' else 'FAIL' end || '|' || replace(coalesce(detail, ''), E'\n', ' ') from mx.results where domain not like 'mut:%' order by seq;
select 'ET27_SUMMARY|checks=' || count(*) filter (where domain not like 'mut:%' and domain not in ('Mutation')) || '|checks_failed=' || count(*) filter (where not ok and domain not like 'mut:%' and domain <> 'Mutation')
       || '|mutants=' || count(*) filter (where domain = 'Mutation') || '|mutants_detected=' || count(*) filter (where domain = 'Mutation' and ok)
       || '|mutants_survived=' || count(*) filter (where domain = 'Mutation' and not ok) from mx.results;
select 'ET27_MUTANT|' || id || '|' || case when ok then 'DETECTED' else 'SURVIVED' end || '|' || detail from mx.results where domain = 'Mutation' order by seq;
do $$
declare bad text;
begin
  select string_agg(id || ' [' || coalesce(detail, '') || ']', E'\n') into bad from mx.results where not ok and domain not like 'mut:%';
  if bad is not null then raise exception E'seal guard checks failed:\n%', bad; end if;
end $$;
rollback;
select 'ok: invocation seal guard (adversarial, coverage, mutation)' as result;
