-- PART D: owner-only restoration. Real roles, real triggers, real catalog. One transaction, rolled back.
-- MUST run as a superuser (it uses SET SESSION AUTHORIZATION and creates roles); CI uses the stack's supabase_admin like the smoke self-test.
\set ON_ERROR_STOP on
begin;
create schema mx;
grant usage on schema mx to public;
create table mx.results (seq bigserial primary key, id text, domain text, ok boolean, detail text);
grant all on all tables in schema mx to public; grant all on all sequences in schema mx to public;
-- A check's result must survive ROLLBACK TO SAVEPOINT (most failure-injection / tamper checks run inside savepoints). Therefore:
--   * every check emits a NOTICE (never rolled back) that the runner parses, and increments a SEQUENCE (also never rolled back);
--   * a FAILING check raises immediately, so psql (ON_ERROR_STOP) exits non-zero. A result can never be silently lost.
create sequence mx.cnt; grant usage, select, update on sequence mx.cnt to public;
create function mx.rec(p_id text, p_domain text, p_ok boolean, p_detail text default null) returns void language plpgsql as $$
begin
  perform nextval('mx.cnt');
  insert into mx.results(id, domain, ok, detail) values (p_id, p_domain, coalesce(p_ok, false), p_detail);
  raise notice 'MXRES|%|%|%|%', case when coalesce(p_ok, false) then 'PASS' else 'FAIL' end, p_id, p_domain, replace(left(coalesce(p_detail, ''), 160), E'\n', ' ');
  if not coalesce(p_ok, false) then raise exception 'CHECK FAILED: % [%] %', p_id, p_domain, left(coalesce(p_detail, ''), 300); end if;
end $$;
-- run SQL, return 'OK' or sqlstate:message
create function mx.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'OK'; exception when others then return sqlstate || ':' || sqlerrm; end $$;
create function mx.val(p_sql text) returns text language plpgsql as $$ declare v text; begin execute p_sql into v; return v; exception when others then return 'ERR ' || sqlstate || ':' || sqlerrm; end $$;
create function mx.try_as(p_role text, p_sql text) returns text language plpgsql as $$
declare r text; begin execute format('set local role %I', p_role); r := mx.try(p_sql); reset role; return r; end $$;
create function mx.enabled(p_t text, p_trg text) returns text language sql as $$ select tgenabled::text from pg_trigger where tgrelid = p_t::regclass and tgname = p_trg $$;
create function mx.drift_kinds() returns text language sql as $$ select coalesce(string_agg(distinct f ->> 'kind', ','), '') from jsonb_array_elements(private.aios_guard_drift() -> 'findings') f $$;
grant usage on schema mx to public;

select mx.rec('D00', 'precondition', (private.aios_final_verify(false) ->> 'overall') = 'VERIFIED' and (select status from private.aios_restoration_state) = 'closed', 'PRECONDITION: the suite needs a freshly replayed database (baseline verifier VERIFIED, no committed unanchored audit events). Got: ' || (private.aios_final_verify(false) ->> 'overall'));
create temp table mx_g0 as select generation as g from private.aios_restoration_state;   -- the suite must not assume generation 0 (races may have advanced it)
grant all on mx_g0 to public;
create role mx_owner login; create role mx_app login;
grant aios_restorer to mx_owner;
grant all on all functions in schema mx to public;

\set C1 '''c1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'''
\set C2 '''c2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'''
\set C3 '''c3-cccccccccccccccccccccccccccccccccccc'''

-- ================================================================== D07 roles and authorization
select mx.rec('D07.1', 'roles', (select not rolcanlogin and not rolsuper and not rolinherit and not rolcreaterole and not rolcreatedb and not rolreplication and not rolbypassrls from pg_roles where rolname = 'aios_restorer'), 'aios_restorer is NOLOGIN, NOINHERIT, no extra attributes');
select mx.rec('D07.2', 'roles', private.aios_restorer_boundary_violations() = '[]'::jsonb, private.aios_restorer_boundary_violations()::text);
select mx.rec('D07.3', 'roles', not exists (select 1 from pg_auth_members m join pg_roles r on r.oid = m.member where m.roleid = 'aios_restorer'::regrole and r.rolname in ('anon','authenticated','service_role','authenticator')), 'no application role holds aios_restorer');
select mx.rec('D07.4', 'roles', not exists (select 1 from pg_auth_members where member = 'aios_restorer'::regrole), 'aios_restorer is a member of nothing');
-- Reverse membership boundaries: neither direct nor transitive app/service membership is accepted.
savepoint s_reverse_membership;
create role mx_bridge nologin;
grant aios_restorer to mx_bridge;
grant mx_bridge to service_role;
select mx.rec('D07.4a', 'roles', pg_has_role('service_role', 'aios_restorer', 'MEMBER')
  and private.aios_restorer_boundary_violations()::text like '%app_role_is_member:service_role%',
  'transitive application membership is detected');
rollback to s_reverse_membership;

savepoint s_restorer_parent;
create role mx_parent nologin;
grant mx_parent to aios_restorer;
select mx.rec('D07.4b', 'roles', private.aios_restorer_boundary_violations()::text like '%restorer_is_member_of_other_roles%',
  'restorer membership in another role is detected');
rollback to s_restorer_parent;

select mx.rec('D07.4c', 'roles',
  (select not rolcanlogin and not rolinherit and not rolsuper and not rolcreatedb
          and not rolcreaterole and not rolreplication and not rolbypassrls
   from pg_catalog.pg_roles where rolname = 'aios_restorer'),
  'all seven restrictive role attributes are verified');
savepoint s_unsafe_existing_role;
alter role aios_restorer login inherit;
select mx.rec('D07.4d', 'roles',
  private.aios_restorer_boundary_violations()::text like '%restorer_can_login%'
  and private.aios_restorer_boundary_violations()::text like '%restorer_inherits_roles%'
  and (select rolcanlogin and rolinherit from pg_catalog.pg_roles where rolname = 'aios_restorer'),
  'unsafe pre-existing attributes are detected and remain unrepaired');
rollback to s_unsafe_existing_role;



-- application roles: no EXECUTE, no table access (every restoration entry point and every table)
select mx.rec('D07.5.' || r.rn || '.' || f.fn, 'authz', mx.try_as(r.rn, f.call) like '42501:%', mx.try_as(r.rn, f.call))
from (values ('service_role'), ('authenticated'), ('anon')) r(rn),
     (values ('install', $$select private.aios_restoration_install_credential(repeat('z', 40))$$), ('open', $$select private.aios_restoration_open(repeat('z', 40), 'a long enough reason')$$),
             ('close', $$select private.aios_restoration_close()$$), ('close_internal', $$select private.aios_restoration_close_internal(1, 'x')$$),
             ('watchdog', $$select private.aios_restoration_watchdog()$$), ('rotate', $$select private.aios_restoration_rotate_credential(repeat('a', 40), repeat('b', 40))$$),
             ('rebaseline', $$select private.aios_guard_rebaseline('a long enough reason')$$),
             ('register', $$select private.aios_guard_register_table('public', 'aios_audit_events')$$),
             ('state_read', $$select * from private.aios_restoration_state$$),
             ('state_write', $$update private.aios_restoration_state set status = 'closed'$$),
             ('registry_write', $$delete from private.aios_guarded_triggers$$),
             ('registry_read', $$select * from private.aios_guarded_triggers$$),
             ('creds_read', $$select * from private.aios_restoration_credentials$$),
             ('log_write', $$insert into private.aios_restoration_log(event) values ('x')$$)) f(fn, call);
-- even aios_restorer members cannot write the registry/state/log tables directly (only through the audited functions)
select mx.rec('D07.6.' || t, 'authz', mx.try_as('aios_restorer', format('select * from private.%I', t)) like '42501:%', t)
from unnest(array['aios_restoration_state', 'aios_guarded_triggers', 'aios_restoration_credentials', 'aios_restoration_log']) t;

-- session-user membership is enforced INDEPENDENTLY of EXECUTE grants: grant EXECUTE+USAGE to PUBLIC (mutation) and a non-member still fails
savepoint s_exec_public;
grant usage on schema private to public;
grant execute on function private.aios_restoration_open(text, text, interval), private.aios_restoration_install_credential(text) to public;
set session authorization mx_app;
select mx.rec('D07.7', 'authz', mx.try($$select private.aios_restoration_open(repeat('z', 40), 'a long enough reason')$$) like '42501:restoration requires owner membership%', mx.try($$select private.aios_restoration_open(repeat('z', 40), 'a long enough reason')$$));
select mx.rec('D07.8', 'authz', mx.try($$select private.aios_restoration_install_credential(repeat('z', 40))$$) like '42501:restoration requires owner membership%');
reset session authorization;
rollback to s_exec_public;

-- JWT claims are not authorization: a non-member session with a forged service_role/owner JWT is still refused
savepoint s_jwt;
grant usage on schema private to public;
grant execute on function private.aios_restoration_open(text, text, interval) to public;
set session authorization mx_app;
select set_config('request.jwt.claims', '{"role":"service_role","sub":"00000000-0000-4000-8000-000000000001"}', true);
select mx.rec('D07.9', 'authz', mx.try($$select private.aios_restoration_open(repeat('z', 40), 'a long enough reason')$$) like '42501:%');
reset session authorization;
rollback to s_jwt;

-- a membership granted to an application role is detected and refuses every operation (boundary check)
savepoint s_member;
grant aios_restorer to service_role;
select mx.rec('D07.10', 'authz', private.aios_restorer_boundary_violations()::text like '%app_role_is_member:service_role%', private.aios_restorer_boundary_violations()::text);
set session authorization mx_owner;
select mx.rec('D07.11', 'authz', mx.try($$select private.aios_restoration_install_credential(repeat('q', 40))$$) like '42501:restorer role boundary violated%', mx.try($$select private.aios_restoration_install_credential(repeat('q', 40))$$));
reset session authorization;
rollback to s_member;

-- application roles cannot grant themselves membership
select mx.rec('D07.12', 'authz', mx.try_as('service_role', 'grant aios_restorer to service_role') like '42501:%');
select mx.rec('D07.13', 'authz', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosrc ~* 'aios_restoration_|aios_restorer'), 'no public/Edge-reachable function references restoration');

-- ================================================================== D03 credential lifecycle (as the owner login)
set session authorization mx_owner;
select mx.rec('D03.1', 'credential', mx.try($$select private.aios_restoration_install_credential('short')$$) like '22023:%', 'short credential rejected');
select mx.rec('D03.2', 'credential', (private.aios_restoration_install_credential(:C1) ->> 'ok')::boolean, 'install ok');
select mx.rec('D03.3', 'credential', mx.try(format('select private.aios_restoration_install_credential(%L)', :C2)) like '55000:%', 'second active credential refused');
reset session authorization;
select mx.rec('D03.4', 'credential', not exists (select 1 from private.aios_restoration_credentials where credential_hash = :C1) and (select credential_hash ~ '^\$2[aby]\$12\$' from private.aios_restoration_credentials limit 1), 'only a bcrypt (cost 12) hash is stored');
select mx.rec('D03.5', 'credential', not exists (select 1 from private.aios_restoration_log where details::text like '%' || :C1 || '%'), 'plaintext never in the log');
set session authorization mx_owner;
select mx.rec('D03.6', 'credential', (private.aios_restoration_open('wrong-credential-wrong-credential-xx', 'attempt with a wrong credential') ->> 'reason') = 'credential_invalid', 'wrong credential returns a denial record');
reset session authorization;
select mx.rec('D03.7', 'credential', (select count(*) from private.aios_restoration_log where event = 'open_denied' and at >= now()) = 1, 'denial persisted (returned, not raised)');
select mx.rec('D03.8', 'credential', (select status from private.aios_restoration_state) = 'closed', 'state unchanged by wrong credential');
set session authorization mx_owner;

-- rotation without an authorization gap; old credential dead afterwards
select mx.rec('D03.9', 'credential', mx.try(format('select private.aios_restoration_rotate_credential(%L, %L)', 'not-the-current-credential-xxxxxxxxxxx', :C2)) like '28000:%', 'rotation requires the current credential');
select mx.rec('D03.10', 'credential', (private.aios_restoration_rotate_credential(:C1, :C2) ->> 'ok')::boolean, 'rotate');
reset session authorization;
select mx.rec('D03.11', 'credential', (select count(*) from private.aios_restoration_credentials where consumed_at is null and revoked_at is null) = 1, 'exactly one active credential after rotation (no gap, no overlap)');
set session authorization mx_owner;
select mx.rec('D03.12', 'credential', (private.aios_restoration_open(:C1, 'old credential must not open a window') ->> 'reason') = 'credential_invalid', 'rotated-out credential rejected');

-- ================================================================== D04 open / state / approved disable set
select mx.rec('D04.0', 'window', mx.try($$select private.aios_restoration_open(repeat('x', 40), 'short')$$) like '22023:%' and mx.try(format('select private.aios_restoration_open(%L, %L, interval ''5 hours'')', :C2, 'a sufficiently long reason')) like '22023:%', 'reason and ttl validated');
create temp table mx_open as select private.aios_restoration_open(:C2, 'restoring audit store from backup', interval '30 minutes') as r;
grant all on mx_open to public;
select mx.rec('D04.1', 'window', (select (r ->> 'ok')::boolean and (r ->> 'triggers_disabled')::int = 4 from mx_open), (select r::text from mx_open));
reset session authorization;
select mx.rec('D04.2', 'window', (select status = 'open' and generation = (select g from mx_g0) + 1 and expires_at > clock_timestamp() from private.aios_restoration_state));
select mx.rec('D04.3', 'window', (select count(*) from pg_trigger where tgrelid = 'public.aios_audit_events'::regclass and tgname in ('trg_aios_audit_hash','trg_aios_audit_immutable_update','trg_aios_audit_immutable_delete','trg_aios_audit_no_truncate') and tgenabled = 'D') = 4, 'the four approved audit triggers are disabled');
select mx.rec('D04.4', 'window', mx.enabled('public.aios_tool_invocations', 'trg_aios_invocation_seal_guard') = 'O' and mx.enabled('public.aios_tool_invocations', 'trg_aios_invocation_no_delete') = 'O' and mx.enabled('private.aios_audit_anchors', 'trg_aios_audit_anchors_no_mutate') = 'A', 'nothing outside the approved set is disabled (anchors stay protected)');
select mx.rec('D04.5', 'window', (private.aios_guard_drift() ->> 'drift_count')::int = 0, 'drift check tolerates ONLY the approved set while the window is open');
select mx.rec('D04.6', 'window', (private.aios_final_verify(false) ->> 'overall') = 'INCOMPLETE', 'verifier never reports VERIFIED while a window is open');
-- consumed credential cannot authorize another window
set session authorization mx_owner;
select mx.rec('D04.7', 'credential', mx.try(format('select private.aios_restoration_open(%L, %L)', :C2, 'second window while first is open')) like '55000:%', 'no second window while open');
reset session authorization;
select mx.rec('D03.13', 'credential', (select consumed_at is not null and consumed_window_id = (select window_id from private.aios_restoration_state) from private.aios_restoration_credentials order by id desc limit 1), 'credential consumed and bound to its window');

-- inside the window the restore may do what the guarded triggers normally forbid; outside it that is impossible
savepoint s_restore;
do $$ declare o uuid := '0a0a0a0a-0000-4000-8000-0000000000d1'; begin
  insert into public.aios_organizations (id, name) values (o, 'mx-part-d');
  insert into public.aios_audit_events (organization_id, event_type, event_hash, previous_event_hash) values (o, 'restored', 'restored-hash-1', 'GENESIS:restored');
  update public.aios_audit_events set event_hash = 'restored-hash-2' where organization_id = o;
  perform mx.rec('D04.8', 'window', (select event_hash from public.aios_audit_events where organization_id = o) = 'restored-hash-2', 'hash trigger disabled: restore hashes are preserved, updates permitted');
end $$;
rollback to s_restore;

-- ================================================================== D04 close: success path
set session authorization mx_owner;
create temp table mx_close as select private.aios_restoration_close() as r;
grant all on mx_close to public;
reset session authorization;
select mx.rec('D04.9', 'close', (select (r ->> 'ok')::boolean and r ->> 'status' = 'closed' from mx_close), (select r::text from mx_close));
select mx.rec('D04.10', 'close', (select count(*) from pg_trigger where tgrelid = 'public.aios_audit_events'::regclass and tgname in ('trg_aios_audit_hash','trg_aios_audit_immutable_update','trg_aios_audit_immutable_delete','trg_aios_audit_no_truncate') and tgenabled = 'A') = 4, 'all four re-enabled as ALWAYS');
select mx.rec('D04.11', 'close', (select status = 'closed' and closed_at is not null from private.aios_restoration_state));
select mx.rec('D04.12', 'close', (private.aios_final_verify(false) ->> 'overall') = 'VERIFIED', 'verifier VERIFIED after a clean close');
select mx.rec('D04.13', 'close', (private.aios_restoration_watchdog() ->> 'no_op')::boolean, 'watchdog is a no-op with nothing to close');

-- ================================================================== D04 failure injection at every step of closure
-- helper to open a fresh window (installs a credential, opens as owner)
create function mx.open_window(p_cred text) returns void language plpgsql as $$
begin
  execute 'set local session authorization mx_owner';
  perform private.aios_restoration_install_credential(p_cred);
  perform private.aios_restoration_open(p_cred, 'failure-injection window for tests');
  execute 'reset session authorization';
end $$;

-- (a) verifier RAISES after trigger re-enablement: re-enablement must survive
savepoint s_verify_raise;
select mx.open_window('d-a-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
create or replace function private.aios_final_verify(p_record boolean default true, p_allow_test_fixtures boolean default false, p_kind text default 'internal') returns jsonb
  language plpgsql as $$ begin raise exception 'injected verifier failure' using errcode = 'XX000'; end $$;
create temp table mx_c1 as select private.aios_restoration_close_internal((select generation from private.aios_restoration_state), 'test') as r;
select mx.rec('D04.F1.a', 'failure', (select r ->> 'status' = 'closed_verification_failed' and (r ->> 'triggers_reenabled')::boolean from mx_c1), (select r::text from mx_c1));
select mx.rec('D04.F1.b', 'failure', (select count(*) from pg_trigger where tgrelid = 'public.aios_audit_events'::regclass and tgname in ('trg_aios_audit_hash','trg_aios_audit_immutable_update','trg_aios_audit_immutable_delete','trg_aios_audit_no_truncate') and tgenabled = 'A') = 4, 'verifier exception did NOT roll back trigger re-enablement');
select mx.rec('D04.F1.c', 'failure', (select status = 'closed_verification_failed' and last_failure ->> 'phase' = 'verify' from private.aios_restoration_state), 'durable failure state');
select mx.rec('D04.F1.d', 'failure', exists (select 1 from private.aios_restoration_log where event = 'verification_failed'), 'durable failure record');
rollback to s_verify_raise;

-- (b) verifier returns ok=false
savepoint s_verify_false;
select mx.open_window('d-b-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
create or replace function private.aios_final_verify(p_record boolean default true, p_allow_test_fixtures boolean default false, p_kind text default 'internal') returns jsonb
  language sql as $$ select jsonb_build_object('ok', false, 'overall', 'FAIL') $$;
create temp table mx_c2 as select private.aios_restoration_close_internal((select generation from private.aios_restoration_state), 'test') as r;
select mx.rec('D04.F2', 'failure', (select r ->> 'status' = 'closed_verification_failed' from mx_c2) and mx.enabled('public.aios_audit_events', 'trg_aios_audit_hash') = 'A', 'ok=false verifier: window closed, triggers enabled, failure recorded');
rollback to s_verify_false;

-- (c) trigger re-enable FAILS for one trigger: explicit critical state, other triggers still re-enabled, watchdog retries
savepoint s_reenable_fail;
select mx.open_window('d-c-cccccccccccccccccccccccccccccccccccc');
update private.aios_guarded_triggers set trigger_name = 'trg_does_not_exist' where trigger_name = 'trg_aios_audit_no_truncate';
create temp table mx_c3 as select private.aios_restoration_close_internal((select generation from private.aios_restoration_state), 'test') as r;
select mx.rec('D04.F3.a', 'failure', (select r ->> 'status' = 'guard_reenable_failed' and not (r ->> 'ok')::boolean from mx_c3), 'never reports success when re-enable failed');
select mx.rec('D04.F3.b', 'failure', mx.enabled('public.aios_audit_events', 'trg_aios_audit_hash') = 'A' and mx.enabled('public.aios_audit_events', 'trg_aios_audit_immutable_update') = 'A', 'triggers that could be re-enabled were (partial progress persists)');
select mx.rec('D04.F3.c', 'failure', (select status = 'guard_reenable_failed' from private.aios_restoration_state) and exists (select 1 from private.aios_restoration_log where event = 'guard_reenable_failed'), 'explicit critical state + durable record');
select mx.rec('D04.F3.d', 'failure', (private.aios_final_verify(false) ->> 'overall') = 'FAIL', 'verifier reports FAIL in guard_reenable_failed');
update private.aios_guarded_triggers set trigger_name = 'trg_aios_audit_no_truncate' where trigger_name = 'trg_does_not_exist';   -- owner repairs the cause
create temp table mx_c3b as select private.aios_restoration_watchdog() as r;
select mx.rec('D04.F3.e', 'failure', (select r ->> 'status' = 'closed' from mx_c3b) and mx.enabled('public.aios_audit_events', 'trg_aios_audit_no_truncate') = 'A', 'watchdog retry completes the closure once the cause is repaired');
rollback to s_reenable_fail;

-- (d) lock_timeout during re-enable (a real lock held on the table by another session is simulated by a failing ALTER target)
savepoint s_table_missing;
select mx.open_window('d-d-dddddddddddddddddddddddddddddddddddd');
update private.aios_guarded_triggers set table_name = 'no_such_table' where trigger_name = 'trg_aios_audit_hash';
create temp table mx_c4 as select private.aios_restoration_close_internal((select generation from private.aios_restoration_state), 'test') as r;
select mx.rec('D04.F4', 'failure', (select r ->> 'status' = 'guard_reenable_failed' from mx_c4), 'missing table during re-enable => guard_reenable_failed, not a raised exception');
rollback to s_table_missing;

-- (e) after a verification failure, the hourly job recovers the state once every other control passes
savepoint s_recover;
select mx.open_window('d-e-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee');
-- realistic end state of a failed closing verification: triggers ARE re-enabled (phase 1 succeeded), only verification failed
alter table public.aios_audit_events enable always trigger trg_aios_audit_hash; alter table public.aios_audit_events enable always trigger trg_aios_audit_immutable_update;
alter table public.aios_audit_events enable always trigger trg_aios_audit_immutable_delete; alter table public.aios_audit_events enable always trigger trg_aios_audit_no_truncate;
update private.aios_restoration_state set status = 'closed_verification_failed', closed_at = clock_timestamp() where id = 1;
select mx.rec('D04.F5.a', 'failure', (private.aios_final_verify(false) ->> 'overall') = 'FAIL', 'closed_verification_failed is FAIL');
select mx.rec('D04.F5.b', 'failure', (select status from private.aios_restoration_state) = 'closed_verification_failed' and (private.aios_scheduled_verify() ->> 'overall') in ('VERIFIED', 'INCOMPLETE'), 'recovery verification ran');
select mx.rec('D04.F5.c', 'failure', (select status from private.aios_restoration_state) = 'closed', 'state recovered by the scheduled verifier when all other controls pass');
rollback to s_recover;

-- ================================================================== D02 watchdog semantics (deterministic; true interleavings are in tests/concurrency/restoration_races.sh)
savepoint s_watchdog;
select mx.open_window('d-w-wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww');
select mx.rec('D02.1', 'watchdog', (private.aios_restoration_watchdog() ->> 'no_op')::boolean, 'unexpired window is left alone');
update private.aios_restoration_state set expires_at = clock_timestamp() - interval '1 second';
create temp table mx_w1 as select private.aios_restoration_watchdog() as r;
select mx.rec('D02.2', 'watchdog', (select r ->> 'status' = 'closed' from mx_w1) and mx.enabled('public.aios_audit_events', 'trg_aios_audit_hash') = 'A', 'expired window closed');
select mx.rec('D02.3', 'watchdog', (private.aios_restoration_watchdog() ->> 'no_op')::boolean, 'idempotent second run');
-- stale generation: a decision made for generation N can never close generation N+1
select mx.open_window('d-w2-wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww');
create temp table mx_w2g as select generation as g from private.aios_restoration_state;   -- generation of the window the 'stale watchdog' inspected
create temp table mx_w2 as select private.aios_restoration_close_internal((select g from mx_w2g) - 1, 'stale-watchdog') as r;
select mx.rec('D02.4', 'watchdog', (select r ->> 'reason' = 'stale_generation' and (r ->> 'no_op')::boolean from mx_w2) and (select status = 'open' and generation = (select g from mx_w2g) from private.aios_restoration_state), 'stale generation is a no-op; the new window stays open');
rollback to s_watchdog;

-- ================================================================== D06 drift detection (every mutation must be detected)
select mx.rec('D06.0', 'drift', (private.aios_guard_drift() ->> 'drift_count')::int = 0 and (private.aios_guard_drift() ->> 'registered_triggers')::int >= 20, 'clean baseline: zero drift, >=20 registered triggers');
savepoint m1; alter table public.aios_audit_events disable trigger trg_aios_audit_immutable_update;
select mx.rec('D06.1', 'drift', mx.drift_kinds() like '%enabled_mode_mismatch%', mx.drift_kinds()); rollback to m1;
savepoint m2; alter table public.aios_audit_events enable trigger trg_aios_audit_hash;     -- ALWAYS -> ORIGIN
select mx.rec('D06.2', 'drift', mx.drift_kinds() like '%enabled_mode_mismatch%', 'ENABLE ALWAYS downgraded to ENABLE: ' || mx.drift_kinds()); rollback to m2;
savepoint m3; drop trigger trg_aios_audit_no_truncate on public.aios_audit_events;
select mx.rec('D06.3', 'drift', mx.drift_kinds() like '%missing_trigger%', mx.drift_kinds()); rollback to m3;
savepoint m4; drop trigger trg_aios_audit_immutable_delete on public.aios_audit_events;
create trigger trg_aios_audit_immutable_delete before delete on public.aios_audit_events for each row execute function private.aios_append_only_guard();
select mx.rec('D06.4', 'drift', mx.drift_kinds() like '%trigger_definition_changed%' and mx.drift_kinds() like '%trigger_function_changed%', 'same name, different function: ' || mx.drift_kinds()); rollback to m4;
savepoint m5; create or replace function private.aios_audit_immutable() returns trigger language plpgsql security definer set search_path = '' as $$ begin return coalesce(new, old); end $$;
select mx.rec('D06.5', 'drift', mx.drift_kinds() like '%trigger_function_changed%', 'trigger function body replaced (weakened): ' || mx.drift_kinds()); rollback to m5;
savepoint m6; drop trigger trg_aios_audit_hash on public.aios_audit_events;
create trigger trg_aios_audit_hash after insert on public.aios_audit_events for each row execute function private.aios_audit_append();
select mx.rec('D06.6', 'drift', mx.drift_kinds() like '%trigger_definition_changed%', 'timing BEFORE->AFTER: ' || mx.drift_kinds()); rollback to m6;
savepoint m7; drop trigger trg_aios_audit_immutable_update on public.aios_audit_events;
create trigger trg_aios_audit_immutable_update before update or delete on public.aios_audit_events for each row execute function private.aios_audit_immutable();
select mx.rec('D06.7', 'drift', mx.drift_kinds() like '%trigger_definition_changed%', 'event coverage changed: ' || mx.drift_kinds()); rollback to m7;
savepoint m8; create trigger trg_sneaky after insert on public.aios_audit_events for each row execute function private.aios_append_only_guard();
select mx.rec('D06.8', 'drift', mx.drift_kinds() like '%unexpected_trigger%', mx.drift_kinds()); rollback to m8;
savepoint m9; drop trigger trg_aios_invocation_seal_guard on public.aios_tool_invocations;
select mx.rec('D06.9', 'drift', mx.drift_kinds() like '%missing_trigger%', 'non-audit protected table also monitored: ' || mx.drift_kinds()); rollback to m9;
savepoint m10; alter table private.aios_audit_anchors disable trigger trg_aios_audit_anchors_no_mutate;
select mx.rec('D06.10', 'drift', mx.drift_kinds() like '%enabled_mode_mismatch%', 'Part E table triggers monitored: ' || mx.drift_kinds()); rollback to m10;
savepoint m11; alter table public.aios_audit_events disable trigger trg_aios_audit_hash;
select mx.rec('D06.11', 'drift', (private.aios_final_verify(false) ->> 'overall') = 'FAIL', 'drift => final verifier FAIL'); rollback to m11;
select mx.rec('D06.12', 'drift', mx.try_as('service_role', $$create trigger t_x after insert on public.aios_audit_events for each row execute function private.aios_append_only_guard()$$) like '42501:%', 'service_role cannot attach a trigger to the audit table (TRIGGER privilege revoked)');
-- rebaseline is owner-only and refuses outside status=closed
select mx.rec('D06.13', 'drift', mx.try_as('service_role', $$select private.aios_guard_rebaseline('a long enough reason text')$$) like '42501:%');

-- ================================================================== D05 schedules
select mx.rec('D05.1', 'schedule', (select count(*) from cron.job where jobname in ('aios-restoration-watchdog', 'aios-audit-verify-hourly')) = 2, 'both new jobs are registered in cron.job');
select mx.rec('D05.2', 'schedule', (select schedule from cron.job where jobname = 'aios-restoration-watchdog') = '*/5 * * * *' and (select schedule from cron.job where jobname = 'aios-audit-verify-hourly') = '7 * * * *');
select mx.rec('D05.3', 'schedule', (private.aios_schedule_check() ->> 'problem_count')::int = 0, private.aios_schedule_check()::text);
set session authorization postgres;   -- cron.job is keyed by (jobname, username): re-register as the same user that migrated
select cron.schedule('aios-restoration-watchdog', '*/5 * * * *', $$select private.aios_restoration_watchdog()$$);
select cron.schedule('aios-audit-verify-hourly', '7 * * * *', $$select private.aios_scheduled_verify()$$);
reset session authorization;
select mx.rec('D05.4', 'schedule', (select count(*) from cron.job where jobname in ('aios-restoration-watchdog', 'aios-audit-verify-hourly')) = 2, 're-registration is idempotent (no duplicate jobs)');
savepoint sj; select cron.unschedule((select jobid from cron.job where jobname = 'aios-restoration-watchdog'));
select mx.rec('D05.5', 'schedule', (private.aios_schedule_check() -> 'problems') @> '[{"kind":"job_missing","job":"aios-restoration-watchdog"}]'::jsonb and (private.aios_final_verify(false) ->> 'overall') = 'FAIL', 'missing watchdog job is detected and fails the verifier'); rollback to sj;
savepoint sj2; select cron.alter_job((select jobid from cron.job where jobname = 'aios-audit-verify-hourly'), schedule := '0 0 1 1 *');
select mx.rec('D05.6', 'schedule', (private.aios_schedule_check() -> 'problems') @> '[{"kind":"schedule_changed","job":"aios-audit-verify-hourly"}]'::jsonb, 'changed schedule detected'); rollback to sj2;
savepoint sj3; select cron.schedule('aios-restoration-watchdog', '*/5 * * * *', $$select private.aios_restoration_watchdog()$$);   -- as root: a second job (different user)
select mx.rec('D05.6b', 'schedule', (private.aios_schedule_check() -> 'problems') @> '[{"kind":"duplicate_job","job":"aios-restoration-watchdog"}]'::jsonb, 'a duplicate job registered by another user is detected'); rollback to sj3;
select mx.rec('D05.7', 'schedule', mx.try_as('service_role', 'select cron.schedule(''x'', ''* * * * *'', ''select 1'')') like '42501:%' and mx.try_as('authenticated', 'select * from cron.job') like '42501:%', 'application roles cannot read or register cron jobs');

-- ================================================================== D01 one canonical verifier; a weaker replacement is detected
select mx.rec('D01.1', 'verifier', (select count(*) from pg_proc where proname = 'aios_final_verify') = 1, 'exactly one aios_final_verify definition');
select mx.rec('D01.2', 'verifier', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.proname ~ '^aios_(final_)?verify' and n.nspname = 'private') = 1, 'no competing verifier implementation in private');
select mx.rec('D01.3', 'verifier', (private.aios_final_verify(false) -> 'controls') ?& array['audit_chain_and_anchors', 'trigger_drift', 'restoration_closed', 'schedules'], 'final verifier combines chain/anchors, drift, restoration and schedules');
savepoint wk; create or replace function private.aios_final_verify(p_record boolean default true, p_allow_test_fixtures boolean default false, p_kind text default 'internal') returns jsonb
  language sql security definer set search_path = '' as $$ select jsonb_build_object('ok', true, 'overall', 'VERIFIED', 'controls', '{}'::jsonb) $$;
select mx.rec('D01.4', 'verifier', (private.aios_scheduled_verify() ->> 'reason') = 'verifier_pin_mismatch', 'a later migration weakening the verifier is caught by the pin check'); rollback to wk;
savepoint wk2; create or replace function private.aios_guard_drift() returns jsonb language sql stable security definer set search_path = '' as $$ select '{"drift_count":0,"findings":[]}'::jsonb $$;
select mx.rec('D01.5', 'verifier', (private.aios_scheduled_verify() ->> 'reason') = 'verifier_pin_mismatch', 'weakened drift check is caught by the pin check'); rollback to wk2;

-- ================================================================== registry cannot be modified by application/service roles; log append-only
select mx.rec('D07.14', 'log', mx.try($$update private.aios_restoration_log set event = 'x'$$) like '42501:%UPDATE%append-only%', 'restoration log UPDATE blocked even for a superuser');
select mx.rec('D07.15', 'log', mx.try($$delete from private.aios_restoration_log$$) like '42501:%DELETE%append-only%');
select mx.rec('D07.16', 'log', mx.try($$truncate private.aios_restoration_log$$) like '42501:%TRUNCATE%append-only%');
set session_replication_role = replica;
select mx.rec('D07.17', 'log', mx.try($$delete from private.aios_restoration_log$$) like '42501:%', 'append-only guard is ENABLE ALWAYS (not bypassed by session_replication_role=replica)');
reset session_replication_role;
select mx.rec('D07.19', 'audit', mx.enabled('public.aios_audit_events', 'trg_aios_audit_immutable_update') = 'A', 'existing audit triggers hardened to ENABLE ALWAYS by this migration');
select mx.rec('D07.20', 'audit', not has_table_privilege('service_role', 'public.aios_audit_events', 'UPDATE') and not has_table_privilege('service_role', 'public.aios_audit_events', 'DELETE') and not has_table_privilege('service_role', 'public.aios_audit_events', 'TRUNCATE') and not has_table_privilege('service_role', 'public.aios_audit_events', 'TRIGGER') and has_table_privilege('service_role', 'public.aios_audit_events', 'INSERT') and has_table_privilege('service_role', 'public.aios_audit_events', 'SELECT'), 'service_role keeps SELECT/INSERT only');

-- ================================================================== report
select 'MXTOTAL|' || last_value || '|checks executed (each emitted a MXRES notice; any failure aborted the script)' from mx.cnt;
rollback;
