-- PART E: independently anchored audit verification. Real triggers, roles and catalog; one transaction, rolled back.
-- MUST run as a superuser, from the repository root (reads tests/golden/audit-golden-vectors.json).
\set ON_ERROR_STOP on
\set golden `cat tests/golden/audit-golden-vectors.json`
begin;
set constraints all immediate;   -- deferrable FKs on audit rows would otherwise leave pending trigger events that block ALTER TABLE in this transaction
create schema mx; grant usage on schema mx to public;
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
create function mx.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'OK'; exception when others then return sqlstate || ':' || sqlerrm; end $$;
create function mx.try_as(p_role text, p_sql text) returns text language plpgsql as $$
declare r text; begin execute format('set local role %I', p_role); r := mx.try(p_sql); reset role; return r; end $$;
create function mx.org(p uuid) returns void language sql as $$ insert into public.aios_organizations (id, name) values (p, 'mx-' || p) $$;
create function mx.ev(p_org uuid, p_type text, p_meta jsonb default '{}', p_at timestamptz default null) returns uuid language sql as
$$ insert into public.aios_audit_events (organization_id, event_type, metadata, created_at) values (p_org, p_type, p_meta, coalesce(p_at, clock_timestamp())) returning id $$;
create function mx.evs(p_org uuid, p_n int) returns void language plpgsql as $$ begin for i in 1..p_n loop perform mx.ev(p_org, 'mx.event', jsonb_build_object('i', i)); end loop; end $$;
-- the event at 1-based position n
create function mx.at(p_org uuid, p_n bigint) returns public.aios_audit_events language sql stable as
$$ select e from public.aios_audit_events e where organization_id = p_org order by created_at, id offset p_n - 1 limit 1 $$;
create function mx.anchor(p_org uuid, p_n bigint, p_type text default 'git', p_class text default null, p_salt text default '') returns jsonb language plpgsql as $$
declare e public.aios_audit_events := mx.at(p_org, p_n); d text; art text; ev jsonb;
begin
  d := private.aios_audit_checkpoint_digest(p_org, p_n, e.id, e.event_hash, e.created_at);
  art := encode(extensions.digest(d || p_type || p_salt, 'sha256'), 'hex');
  ev := case p_type when 'git' then jsonb_build_object('repository', 'example/audit-checkpoints', 'commit', repeat('a', 40), 'manifest_path', 'cp/' || p_n || '.txt', 'manifest_sha256', d, 'verified_by', 'mx-test')
        else jsonb_build_object('message_imprint', d, 'token_sha256', art, 'tsa_name', 'TEST-TSA', 'gen_time', '2026-01-01T00:00:00Z', 'verified_by', 'mx-test') end
        || case when p_class is null then '{}'::jsonb else jsonb_build_object('class', p_class) end;
  return private.aios_audit_record_anchor(p_org, p_n, e.id, e.event_hash, e.created_at, p_type, art, 'test://artifact/' || p_n, ev);
end $$;
create function mx.ext(p_org uuid, p_anchor bigint, p_ok boolean default true) returns jsonb language plpgsql as $$
declare a private.aios_audit_anchors;
begin select * into a from private.aios_audit_anchors where id = p_anchor;
  return private.aios_audit_record_external_verification(p_org, a.id, a.event_count, a.head_hash, repeat('c', 64), p_ok, '{"test":true}'); end $$;
create function mx.st(p_org uuid, p_fixtures boolean default false) returns text language sql as
$$ select o ->> 'status' from jsonb_array_elements(private.aios_final_verify(false, p_fixtures) -> 'organizations') o where (o ->> 'organization_id')::uuid = p_org $$;
create function mx.tamper_on() returns void language plpgsql as $$ begin
  alter table public.aios_audit_events disable trigger trg_aios_audit_hash; alter table public.aios_audit_events disable trigger trg_aios_audit_immutable_update;
  alter table public.aios_audit_events disable trigger trg_aios_audit_immutable_delete; end $$;
grant all on all functions in schema mx to public;

\set A '''aa000000-0000-4000-8000-00000000000a'''
\set B '''bb000000-0000-4000-8000-00000000000b'''
\set C '''cc000000-0000-4000-8000-00000000000c'''

-- ================================================================== E02 canonical algorithm == historical algorithm
-- (1) every committed golden vector: re-inserting the golden inputs through the REAL trigger reproduces the committed hash, and the canonical functions agree
create temp table mx_golden as select :'golden'::jsonb as g;
grant all on mx_golden to public;
do $$ declare g jsonb := (select mx_golden.g from mx_golden); v jsonb; e jsonb; n int := 0; bad int := 0; r public.aios_audit_events; prev text; pay text; org uuid;
begin
  for org in select distinct (x ->> 'organization_id')::uuid from jsonb_array_elements(g -> 'vectors') x loop
    insert into public.aios_organizations (id, name) values (org, 'golden-' || org) on conflict do nothing;
  end loop;
  for v in select * from jsonb_array_elements(g -> 'vectors') loop
    e := v -> 'event';
    insert into public.aios_audit_events (id, organization_id, event_type, tool_name, previous_state, new_state, arguments_hash, risk_level, created_at, metadata)
    values ((e ->> 'id')::uuid, (e ->> 'organization_id')::uuid, e ->> 'event_type', e ->> 'tool_name', e ->> 'previous_state', e ->> 'new_state', e ->> 'arguments_hash', e ->> 'risk_level', (e ->> 'created_at')::timestamptz, e -> 'metadata');
  end loop;
  for v in select * from jsonb_array_elements(g -> 'vectors') loop
    n := n + 1;
    select * into r from public.aios_audit_events where id = ((v -> 'event') ->> 'id')::uuid;
    prev := r.previous_event_hash;
    pay := private.aios_audit_canonical_payload(r, prev);
    if r.event_hash is distinct from v ->> 'expected_event_hash' or pay is distinct from v ->> 'expected_payload' or private.aios_audit_canonical_hash(r, prev) is distinct from v ->> 'expected_event_hash'
       or to_jsonb(r.created_at) #>> '{}' is distinct from v ->> 'created_at_canonical' then bad := bad + 1; end if;
  end loop;
  perform mx.rec('E02.1', 'golden', n >= 5 and bad = 0, format('%s golden vectors, %s mismatches (trigger hash, canonical payload, canonical hash, timestamp text)', n, bad));
end $$;
select mx.rec('E02.2', 'golden', (private.aios_audit_verify_chain_v2('0a0a0a0a-0000-4000-8000-00000000601d') ->> 'valid')::boolean and (private.aios_audit_verify_chain_v2('0a0a0a0a-0000-4000-8000-00000000602d') ->> 'valid')::boolean, 'chain valid for both golden organizations');
select mx.rec('E02.3', 'golden', (select (private.aios_audit_canonical_payload(e, e.previous_event_hash)) like '%"previous_event_hash": "' || e.previous_event_hash || '"}' || e.previous_event_hash from public.aios_audit_events e where id = '00000000-0000-4000-8000-000000000002'), 'previous_event_hash is included in the JSON AND concatenated again (historical double inclusion)');
select mx.rec('E02.4', 'golden', (select created_at = '2026-01-01 00:00:00.120001+00' from public.aios_audit_events where id = '00000000-0000-4000-8000-000000000003'), 'timestamp collision: created_at advanced by exactly 1 microsecond');
select set_config('request.jwt.claims', '{"role":"service_role"}', true);   -- the legacy verifier authorizes via auth.jwt()
-- (2) cross-check against the LEGACY verifier (independent historical implementation, session TimeZone UTC)
select mx.rec('E02.5', 'golden', (private.verify_audit_chain('0a0a0a0a-0000-4000-8000-00000000601d') ->> 'valid')::boolean and (private.verify_audit_chain('0a0a0a0a-0000-4000-8000-00000000601d') ->> 'events_checked')::int = 4, 'legacy private.verify_audit_chain agrees with the canonical verifier');
-- (3) timezone: canonical functions are session-TimeZone independent; the historical append is NOT (finding) and fails closed
set timezone = 'Asia/Tokyo';
select mx.rec('E02.6', 'golden', (private.aios_audit_verify_chain_v2('0a0a0a0a-0000-4000-8000-00000000601d') ->> 'valid')::boolean, 'canonical verification is independent of the verifier session TimeZone');
select mx.rec('E02.7', 'golden', not (private.verify_audit_chain('0a0a0a0a-0000-4000-8000-00000000601d') ->> 'valid')::boolean, 'FINDING: the legacy verifier is session-TimeZone dependent (valid under UTC, invalid under Asia/Tokyo)');
savepoint s_tz;
select mx.org(:C);
select mx.ev(:C, 'tokyo.append', '{}', '2026-02-01 00:00:00+00');
reset timezone;
select mx.rec('E02.8', 'golden', (private.aios_audit_verify_chain_v2(:C) ->> 'valid')::boolean is false and (private.aios_audit_verify_chain_v2(:C) ->> 'reason') = 'event_hash_mismatch', 'FINDING: an event appended under a non-UTC session TimeZone hashes differently and verifies as chain_mismatch (fail-closed)');
rollback to s_tz;
reset timezone;   -- the savepoint was taken while TimeZone was Asia/Tokyo; restore UTC for the rest of the suite
select mx.org(:C), mx.ev(:C, 'single.event');

-- ================================================================== world: orgs A (6 events), B (3 events)
select mx.org(:A), mx.org(:B);
select mx.evs(:A, 6), mx.evs(:B, 3);
select mx.rec('E02.9', 'golden', (private.aios_audit_verify_chain_v2(:A) ->> 'valid')::boolean and (private.aios_audit_verify_chain_v2(:A) ->> 'events_checked')::int = 6, 'org A chain valid (6 events, one shared transaction timestamp => collision advances)');
select mx.rec('E02.10', 'golden', (select count(distinct created_at) from public.aios_audit_events where organization_id = :A) = 6, 'every event has a distinct created_at (ordering is total)');
select mx.rec('E02.11', 'golden', (private.aios_audit_verify_chain_v2(:A) ->> 'head_hash') <> (private.aios_audit_verify_chain_v2(:B) ->> 'head_hash') and (select previous_event_hash from public.aios_audit_events where organization_id = :B order by created_at, id limit 1) = 'GENESIS:' || :B, 'organizations have independent chains with per-organization genesis');

-- ================================================================== E01 coverage: an empty anchor table can NEVER yield a verified organization
select mx.rec('E01.1', 'coverage', not exists (select 1 from private.aios_audit_anchors where organization_id = :A), 'precondition: no anchors for A');
select mx.rec('E01.2', 'coverage', mx.st(:A) = 'valid_unanchored' and mx.st(:B) = 'valid_unanchored', 'valid chain without an anchor is valid_unanchored, not verified');
select mx.rec('E01.3', 'coverage', (private.aios_final_verify(false) ->> 'ok')::boolean is false and (private.aios_final_verify(false) ->> 'overall') = 'INCOMPLETE', 'global ok=false / INCOMPLETE with unanchored organizations');
select mx.rec('E01.4', 'coverage', (private.aios_final_verify(false) ->> 'certification_grade')::boolean is false and (private.aios_final_verify(false) ->> 'partial')::boolean is false and private.aios_final_verify(false) ->> 'external_attestation_trust' = 'service_role_asserted', 'DB result is never certification grade; partial verification does not exist');

-- ================================================================== E03 anchor validation
select mx.rec('E03.1', 'anchor', (mx.anchor(:A, 3) ->> 'ok')::boolean, 'valid anchor at position 3 accepted');
select mx.rec('E03.2', 'anchor', (mx.anchor(:A, 3) ->> 'idempotent')::boolean, 'identical resubmission is idempotent');
select mx.rec('E03.3', 'anchor', (select count(*) from private.aios_audit_anchors where organization_id = :A) = 1, 'idempotent resubmission created no duplicate');
-- timestamp binding
select mx.rec('E03.4', 'anchor', mx.try(format($q$select private.aios_audit_record_anchor(%L, 4, %L, %L, %L, 'git', %L, 'x', %L)$q$, :A, (mx.at(:A,4)).id, (mx.at(:A,4)).event_hash, (mx.at(:A,4)).created_at + interval '1 microsecond', repeat('d', 64),
   jsonb_build_object('repository','r','commit',repeat('a',40),'manifest_path','p','manifest_sha256', private.aios_audit_checkpoint_digest(:A, 4, (mx.at(:A,4)).id, (mx.at(:A,4)).event_hash, (mx.at(:A,4)).created_at + interval '1 microsecond'),'verified_by','x'))) like '22023:head_at does not match%', 'a timestamp off by 1 microsecond is rejected even though the hash is correct');
select mx.rec('E03.5', 'anchor', mx.try(format($q$select private.aios_audit_record_anchor(%L, 99, %L, %L, now(), 'git', %L, 'x', '{}')$q$, :A, (mx.at(:A,4)).id, (mx.at(:A,4)).event_hash, repeat('d', 64))) like '22023:event_count 99 does not exist%', 'nonexistent event_count rejected');
select mx.rec('E03.6', 'anchor', mx.try(format($q$select private.aios_audit_record_anchor(%L, 4, %L, %L, %L, 'git', %L, 'x', '{}')$q$, :A, (mx.at(:A,4)).id, repeat('0', 64), (mx.at(:A,4)).created_at, repeat('d', 64))) like '22023:head_hash does not match%', 'wrong head hash rejected');
select mx.rec('E03.7', 'anchor', mx.try(format($q$select private.aios_audit_record_anchor(%L, 4, %L, %L, %L, 'git', %L, 'x', '{}')$q$, :A, (mx.at(:A,5)).id, (mx.at(:A,4)).event_hash, (mx.at(:A,4)).created_at, repeat('d', 64))) like '22023:head_event_id does not match%', 'wrong head event id rejected');
select mx.rec('E03.8', 'anchor', mx.try(format($q$select mx.anchor(%L, 2)$q$, :A)) like '22023:anchor regression%', 'anchor behind the latest accepted anchor rejected');
select mx.rec('E03.9', 'anchor', (mx.anchor(:A, 5, 'rfc3161') ->> 'ok')::boolean, 'rfc3161 anchor at 5 accepted (structure + imprint binding only)');
select mx.rec('E03.10', 'anchor', (mx.anchor(:A, 5, 'rfc3161') ->> 'authenticity') is null and (select (mx.anchor(:A, 5, 'git') ->> 'authenticity') = 'NOT_VERIFIED_BY_DATABASE'), 'a second evidence type at the same position is accepted; the DB reports authenticity NOT_VERIFIED_BY_DATABASE');
-- evidence binding: imprint/manifest must equal the checkpoint digest
select mx.rec('E03.11', 'anchor', mx.try(format($q$select private.aios_audit_record_anchor(%L, 6, %L, %L, %L, 'rfc3161', %L, 'x', %L)$q$, :A, (mx.at(:A,6)).id, (mx.at(:A,6)).event_hash, (mx.at(:A,6)).created_at, repeat('e', 64),
   jsonb_build_object('message_imprint', repeat('f', 64), 'token_sha256', repeat('e', 64), 'tsa_name', 't', 'gen_time', 'g', 'verified_by', 'x'))) like '22023:rfc3161 message_imprint does not equal%', 'rfc3161 token whose imprint covers a DIFFERENT digest is rejected');
select mx.rec('E03.12', 'anchor', mx.try(format($q$select private.aios_audit_record_anchor(%L, 6, %L, %L, %L, 'git', %L, 'x', %L)$q$, :A, (mx.at(:A,6)).id, (mx.at(:A,6)).event_hash, (mx.at(:A,6)).created_at, repeat('e', 64),
   jsonb_build_object('repository', 'r', 'commit', 'not-a-sha', 'manifest_path', 'p', 'manifest_sha256', private.aios_audit_checkpoint_digest(:A, 6, (mx.at(:A,6)).id, (mx.at(:A,6)).event_hash, (mx.at(:A,6)).created_at), 'verified_by', 'x'))) like '22023:git evidence requires%', 'fabricated git reference (not a 40-hex commit) rejected');
select mx.rec('E03.13', 'anchor', mx.try(format($q$select private.aios_audit_record_anchor(%L, 6, %L, %L, %L, 'x509', %L, 'x', '{}')$q$, :A, (mx.at(:A,6)).id, (mx.at(:A,6)).event_hash, (mx.at(:A,6)).created_at, repeat('e', 64))) like '22023:unsupported evidence type%', 'unknown evidence type rejected');
select mx.rec('E03.14', 'anchor', mx.try(format($q$select private.aios_audit_record_anchor(%L, 6, %L, %L, %L, 'git', 'XYZ', 'x', '{}')$q$, :A, (mx.at(:A,6)).id, (mx.at(:A,6)).event_hash, (mx.at(:A,6)).created_at)) like '22023:hashes must be%', 'malformed artifact hash rejected');
-- the chain must be valid up to the anchored position
savepoint s_badchain; select mx.tamper_on(); update public.aios_audit_events set metadata = '{"x":1}' where id = (mx.at(:B, 2)).id;
select mx.rec('E03.15', 'anchor', mx.try(format($q$select mx.anchor(%L, 3)$q$, :B)) like '22023:audit chain invalid before anchored position%', 'cannot anchor a history whose chain is already broken'); rollback to s_badchain;

-- ================================================================== E01 states with anchors / external attestation
select mx.rec('E01.5', 'coverage', mx.st(:A) = 'stale_anchor' is false and mx.st(:A) = 'anchored_unattested', 'anchored (latest = position 5 of 6, tail within tolerance) but no external verification => anchored_unattested, not verified');
select mx.rec('E01.6', 'coverage', (private.aios_final_verify(false) ->> 'ok')::boolean is false, 'global ok=false while any organization is not verified');
select mx.rec('E01.7', 'coverage', (mx.ext(:A, (select max(id) from private.aios_audit_anchors where organization_id = :A and event_count = 5)) ->> 'ok')::boolean and mx.st(:A) = 'verified', 'external verification bound to the latest anchor => verified');
select mx.rec('E01.8', 'coverage', mx.try(format($q$select private.aios_audit_record_external_verification(%L, %s, 99, %L, %L, true, '{}')$q$, :A, (select min(id) from private.aios_audit_anchors where organization_id = :A), repeat('0', 64), repeat('c', 64))) like '22023:report does not match the anchor%', 'external verification must match the anchor count/head');
select mx.rec('E01.9', 'coverage', mx.try(format($q$select private.aios_audit_record_external_verification(%L, 424242, 5, %L, %L, true, '{}')$q$, :A, repeat('0', 64), repeat('c', 64))) like '22023:unknown anchor%', 'external verification of an unknown anchor rejected');
-- failed external verification
savepoint s_extfail; select mx.ext(:A, (select max(id) from private.aios_audit_anchors where organization_id = :A), false);
select mx.rec('E01.10', 'coverage', mx.st(:A) = 'external_verification_failed' and (private.aios_final_verify(false) ->> 'overall') = 'FAIL', 'a failed external verification is FAIL (an outage must not look like success; a failure is never converted to success)'); rollback to s_extfail;
-- external verification goes stale
savepoint s_extstale; insert into private.aios_audit_verification_runs (organization_id, kind, status, ok, anchor_id, event_count, head_hash, finished_at)
  select :A, 'external', 'external_verified', true, a.id, a.event_count, a.head_hash, clock_timestamp() - interval '3 hours' from private.aios_audit_anchors a where a.organization_id = :A and a.event_count = 5 limit 1;
delete from private.aios_audit_verification_runs where false;  -- (append-only; nothing to delete)
rollback to s_extstale;
-- test fixtures are never production-verified
select mx.org('dd000000-0000-4000-8000-00000000000d'); select mx.evs('dd000000-0000-4000-8000-00000000000d', 2);
select mx.anchor('dd000000-0000-4000-8000-00000000000d', 2, 'git', 'TEST_FIXTURE');
select mx.ext('dd000000-0000-4000-8000-00000000000d', (select max(id) from private.aios_audit_anchors where organization_id = 'dd000000-0000-4000-8000-00000000000d'));
select mx.rec('E01.11', 'coverage', mx.st('dd000000-0000-4000-8000-00000000000d') = 'anchor_untrusted_fixture' and mx.st('dd000000-0000-4000-8000-00000000000d', true) = 'verified', 'TEST_FIXTURE anchors are rejected by the production verifier and accepted only with the explicit test flag');

-- ================================================================== E07 freshness boundaries (policy: 2h)
-- fresh: the oldest unanchored event is 5 seconds INSIDE the threshold
select mx.org('f1000000-0000-4000-8000-000000000001'), mx.org('f2000000-0000-4000-8000-000000000002');
select mx.ev('f1000000-0000-4000-8000-000000000001', 'old', '{}', clock_timestamp() - interval '5 hours');
select mx.ev('f2000000-0000-4000-8000-000000000002', 'old', '{}', clock_timestamp() - interval '5 hours');
select mx.anchor('f1000000-0000-4000-8000-000000000001', 1), mx.anchor('f2000000-0000-4000-8000-000000000002', 1);
select mx.ev('f1000000-0000-4000-8000-000000000001', 'tail', '{}', clock_timestamp() - interval '2 hours' + interval '5 seconds');
select mx.ev('f2000000-0000-4000-8000-000000000002', 'tail', '{}', clock_timestamp() - interval '2 hours' - interval '5 seconds');
select mx.ext('f1000000-0000-4000-8000-000000000001', (select max(id) from private.aios_audit_anchors where organization_id = 'f1000000-0000-4000-8000-000000000001'));
select mx.ext('f2000000-0000-4000-8000-000000000002', (select max(id) from private.aios_audit_anchors where organization_id = 'f2000000-0000-4000-8000-000000000002'));
select mx.rec('E07.1', 'freshness', mx.st('f1000000-0000-4000-8000-000000000001') = 'verified', 'unanchored tail 5s inside the policy window is tolerated (not stale)');
select mx.rec('E07.2', 'freshness', mx.st('f2000000-0000-4000-8000-000000000002') = 'stale_anchor', 'unanchored tail 5s outside the policy window => stale_anchor');
select mx.rec('E07.3', 'freshness', (private.aios_final_verify(false) ->> 'overall') in ('FAIL', 'INCOMPLETE') and (private.aios_final_verify(false) ->> 'ok')::boolean is false, 'a stale organization prevents global ok');
-- policy by event count
savepoint s_pol; update private.aios_audit_anchor_policy set max_unanchored_events = 1;
select mx.evs('f1000000-0000-4000-8000-000000000001', 1);
select mx.rec('E07.4', 'freshness', mx.st('f1000000-0000-4000-8000-000000000001') = 'stale_anchor', 'max_unanchored_events policy enforced'); rollback to s_pol;
select mx.rec('E07.5', 'freshness', mx.try_as('service_role', 'update private.aios_audit_anchor_policy set max_unanchored_age = interval ''24 hours''') like '42501:%' and mx.try_as('service_role', $$select private.aios_audit_policy_set(interval '1 hour', interval '1 hour', 'a long enough reason')$$) like '42501:%', 'service_role cannot change the freshness policy');

-- ================================================================== tamper / truncation / rewrite detection (each in a savepoint)
-- org A: anchored at 3 and 5 (git+rfc3161), 6 events
savepoint t1; select mx.tamper_on(); update public.aios_audit_events set metadata = '{"tampered":true}' where id = (mx.at(:A, 2)).id;
select mx.rec('T1', 'tamper', mx.st(:A) = 'chain_mismatch', 'altered event metadata => chain_mismatch'); rollback to t1;
savepoint t2; select mx.tamper_on(); update public.aios_audit_events set event_hash = repeat('0', 64) where id = (mx.at(:A, 4)).id;
select mx.rec('T2', 'tamper', mx.st(:A) = 'chain_mismatch', 'altered event hash => chain_mismatch'); rollback to t2;
savepoint t3; select mx.tamper_on(); update public.aios_audit_events set previous_event_hash = repeat('1', 64) where id = (mx.at(:A, 4)).id;
select mx.rec('T3', 'tamper', mx.st(:A) = 'chain_mismatch' and (private.aios_audit_verify_chain_v2(:A) ->> 'reason') = 'previous_hash_mismatch', 'altered previous-event hash => chain_mismatch'); rollback to t3;
savepoint t4; select mx.tamper_on(); delete from public.aios_audit_events where id = (mx.at(:A, 2)).id;
select mx.rec('T4', 'tamper', mx.st(:A) = 'chain_mismatch', 'deleted historical event => chain_mismatch'); rollback to t4;
savepoint t5; select mx.tamper_on(); delete from public.aios_audit_events where id = (mx.at(:A, 6)).id;
select mx.rec('T5a', 'tamper', (private.aios_audit_verify_chain_v2(:A) ->> 'valid')::boolean, 'truncating the TAIL keeps a valid cryptographic chain (this is exactly why external anchors exist)');
select mx.rec('T5b', 'tamper', mx.st(:A) = 'verified', 'tail removed BEFORE the latest anchor position is still covered: anchor at 5 matches');
delete from public.aios_audit_events where id = (mx.at(:A, 5)).id;
select mx.rec('T5c', 'tamper', mx.st(:A) = 'truncated_history', 'history shorter than an accepted anchor => truncated_history'); rollback to t5;
savepoint t6; select mx.tamper_on(); delete from public.aios_audit_events where organization_id = :A;
select mx.rec('T6', 'tamper', mx.st(:A) = 'truncated_history', 'all events removed while anchors exist => truncated_history'); rollback to t6;
-- full history rewrite with every later hash recomputed: the chain is valid again, but the anchor catches it
savepoint t7; select mx.tamper_on();
do $$ declare r public.aios_audit_events; prev text := 'GENESIS:aa000000-0000-4000-8000-00000000000a'; h text; n int := 0;
begin
  update public.aios_audit_events set metadata = '{"rewritten":true}' where id = (mx.at('aa000000-0000-4000-8000-00000000000a', 2)).id;
  for r in select * from public.aios_audit_events where organization_id = 'aa000000-0000-4000-8000-00000000000a' order by created_at, id loop
    h := private.aios_audit_canonical_hash(r, prev);
    update public.aios_audit_events set previous_event_hash = prev, event_hash = h where id = r.id; prev := h; n := n + 1;
  end loop;
end $$;
select mx.rec('T7a', 'tamper', (private.aios_audit_verify_chain_v2(:A) ->> 'valid')::boolean, 'a consistently resealed history is a VALID chain (the database cannot detect this alone)');
select mx.rec('T7b', 'tamper', mx.st(:A) = 'anchor_mismatch', 'the external anchor detects the resealed history => anchor_mismatch'); rollback to t7;
-- tampered anchor timestamp on the event (hash intact) is also caught
savepoint t8; select mx.tamper_on(); update public.aios_audit_events set created_at = created_at + interval '1 microsecond' where id = (mx.at(:A, 5)).id;
select mx.rec('T8', 'tamper', mx.st(:A) in ('chain_mismatch', 'anchor_mismatch'), 'altered event timestamp detected'); rollback to t8;

-- ================================================================== E08 export / pagination
select mx.org('ee000000-0000-4000-8000-00000000000e'); select mx.evs('ee000000-0000-4000-8000-00000000000e', 25);
select mx.rec('E08.1', 'export', mx.try($$select private.aios_audit_chain_export('ee000000-0000-4000-8000-00000000000e', -1, 10)$$) like '22023:%' and mx.try($$select private.aios_audit_chain_export('ee000000-0000-4000-8000-00000000000e', 0, 0)$$) like '22023:%' and mx.try($$select private.aios_audit_chain_export('ee000000-0000-4000-8000-00000000000e', 0, 1001)$$) like '22023:%' and mx.try($$select private.aios_audit_chain_export(null, 0, 10)$$) like '22023:%', 'negative offset, zero/oversized limit and null organization rejected');
create temp table mx_pages as
  select p, private.aios_audit_chain_export('ee000000-0000-4000-8000-00000000000e', (p - 1) * 10, 10) as j from generate_series(1, 3) p;
grant all on mx_pages to public;
select mx.rec('E08.2', 'export', (select array_agg((e ->> 'seq')::int order by p, ord) from mx_pages, jsonb_array_elements(j -> 'events') with ordinality t(e, ord)) = (select array_agg(i) from generate_series(1, 25) i), 'pages 1..3 cover seq 1..25 with no skips or duplicates');
select mx.rec('E08.3', 'export', (select array_agg((j ->> 'has_more')::boolean order by p) from mx_pages) = array[true, true, false] and (select count(distinct j ->> 'head_hash') from mx_pages) = 1 and (select count(distinct j ->> 'total_events') from mx_pages) = 1, 'has_more correct; every page carries the same head/total (one consistent snapshot)');
select mx.rec('E08.4', 'export', (private.aios_audit_chain_export('ee000000-0000-4000-8000-00000000000e', 25, 10) ->> 'returned')::int = 0 and (private.aios_audit_chain_export('ee000000-0000-4000-8000-00000000000e', 999, 10) ->> 'returned')::int = 0, 'offset at/after the end returns an empty page');
select mx.rec('E08.5', 'export', (private.aios_audit_chain_export(:C, 0, 10) ->> 'total_events')::int = 1 and (private.aios_audit_chain_export('99999999-0000-4000-8000-000000000000', 0, 10) ->> 'total_events')::int = 0 and jsonb_array_length(private.aios_audit_chain_export('99999999-0000-4000-8000-000000000000', 0, 10) -> 'events') = 0, 'empty history exports cleanly');
-- concurrent append between pages is DETECTABLE by the consumer (total/head change) and never corrupts earlier pages
create temp table mx_drift as select private.aios_audit_chain_export('ee000000-0000-4000-8000-00000000000e', 0, 10) as p1;
select mx.ev('ee000000-0000-4000-8000-00000000000e', 'appended.between.pages');
create temp table mx_drift2 as select private.aios_audit_chain_export('ee000000-0000-4000-8000-00000000000e', 10, 10) as p2;
grant all on mx_drift, mx_drift2 to public;
select mx.rec('E08.6', 'export', (select (p1 ->> 'total_events') <> (p2 ->> 'total_events') and (p1 ->> 'head_hash') <> (p2 ->> 'head_hash') from mx_drift, mx_drift2), 'concurrent append between pages is detectable (total_events/head_hash differ)');
select mx.rec('E08.7', 'export', (select (p2 -> 'events' -> 0 ->> 'previous_event_hash') = (p1 -> 'events' -> 9 ->> 'event_hash') from mx_drift, mx_drift2), 'pages remain chain-contiguous despite the append');
select mx.rec('E08.8', 'export', (select bool_and(e ? 'created_at' and e ? 'metadata' and e ? 'event_hash' and e ? 'previous_event_hash') from mx_pages, jsonb_array_elements(j -> 'events') e), 'every exported event carries the canonical fields');

-- ================================================================== E09 immutability of anchors and verification runs
select mx.rec('E09.' || t || '.' || op, 'immutable', mx.try(sql) like '42501:%append-only%', mx.try(sql))
from unnest(array['aios_audit_anchors', 'aios_audit_verification_runs']) t,
     lateral (values ('update', format('update private.%I set recorded_by = recorded_by', t)), ('delete', format('delete from private.%I', t)), ('truncate', format('truncate private.%I cascade', t))) v(op, sql);
set session_replication_role = replica;
select mx.rec('E09.replica.' || t, 'immutable', mx.try(format('delete from private.%I', t)) like '42501:%append-only%', 'ENABLE ALWAYS: session_replication_role=replica does not bypass'),
       mx.rec('E09.alwaysmode.' || t, 'immutable', (select bool_and(tgenabled = 'A') from pg_trigger where tgrelid = ('private.' || t)::regclass and not tgisinternal), 'both triggers are ENABLE ALWAYS')
from unnest(array['aios_audit_anchors', 'aios_audit_verification_runs']) t;
reset session_replication_role;
select mx.rec('E09.roles.' || r || '.' || t, 'immutable', mx.try_as(r, format('select * from private.%I', t)) like '42501:%', r || ' cannot read ' || t)
from unnest(array['service_role', 'authenticated', 'anon']) r, unnest(array['aios_audit_anchors', 'aios_audit_verification_runs', 'aios_audit_anchor_policy', 'aios_function_pins']) t;
select mx.rec('E09.write.' || r, 'immutable', mx.try_as(r, 'insert into private.aios_audit_anchors (organization_id,event_count,head_event_id,head_hash,head_at,evidence_type,checkpoint_sha256,artifact_sha256,artifact_ref) values (gen_random_uuid(),1,gen_random_uuid(),repeat(''a'',64),now(),''git'',repeat(''a'',64),repeat(''a'',64),''x'')') like '42501:%', r || ' cannot insert anchors directly')
from unnest(array['service_role', 'authenticated', 'anon']) r;
savepoint s_m; alter table private.aios_audit_verification_runs disable trigger trg_aios_audit_verification_runs_no_mutate;
select mx.rec('E09.mutation', 'immutable', (select count(*) from jsonb_array_elements(private.aios_guard_drift() -> 'findings') f where f ->> 'kind' = 'enabled_mode_mismatch') = 1 and (private.aios_final_verify(false) ->> 'overall') = 'FAIL', 'disabling an immutability trigger is detected as drift and fails the verifier'); rollback to s_m;

-- ================================================================== wrappers: service_role only
select mx.rec('W.' || f.n || '.' || r, 'wrappers', mx.try_as(r, f.call) like '42501:%', mx.try_as(r, f.call))
from unnest(array['authenticated', 'anon']) r,
     (values ('export', $$select public.aios_audit_chain_export('aa000000-0000-4000-8000-00000000000a', 0, 5)$$), ('heads', 'select public.aios_audit_heads()'), ('verify', 'select public.aios_audit_verify()'),
             ('anchor', $$select public.aios_audit_record_anchor(gen_random_uuid(), 1, gen_random_uuid(), repeat('a',64), now(), 'git', repeat('a',64), 'x', '{}')$$),
             ('ext', $$select public.aios_audit_record_external_verification(gen_random_uuid(), 1, 1, repeat('a',64), repeat('a',64), true, '{}')$$)) f(n, call);
select mx.rec('W.service.export', 'wrappers', mx.try_as('service_role', $$select public.aios_audit_chain_export('aa000000-0000-4000-8000-00000000000a', 0, 5)$$) = 'OK', 'service_role may export');
select mx.rec('W.service.heads', 'wrappers', mx.try_as('service_role', 'select public.aios_audit_heads()') = 'OK');
select mx.try_as('service_role', 'select public.aios_audit_verify()') as service_verify_result \gset
select mx.rec('W.service.verify', 'wrappers', :'service_verify_result' = 'OK' and exists (select 1 from private.aios_audit_verification_runs where kind = 'internal' and organization_id is null), 'service_role may run the verifier; the global run is recorded');
select mx.rec('W.private', 'wrappers', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'private' and p.proname ~ '^aios_(audit|final|scheduled)' and (has_function_privilege('service_role', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE') or has_function_privilege('anon', p.oid, 'EXECUTE'))), 'no Part E private function is executable by application roles');
select mx.rec('W.definer', 'wrappers', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('private', 'public') and p.prosecdef and p.proname ~ '^aios_(audit|final|scheduled|restoration|guard)' and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c = 'search_path=""')), 'every new SECURITY DEFINER function pins search_path = ''''');

-- ================================================================== verification run recording
select mx.rec('R.1', 'runs', (select count(*) from private.aios_audit_verification_runs where kind = 'external') >= 2 and (select count(*) from private.aios_audit_verification_runs where kind = 'internal') >= 1, 'internal and external runs are recorded');
create temp table mx_sched as select private.aios_scheduled_verify() as r;
grant all on mx_sched to public;
select mx.rec('R.2', 'runs', (select r ->> 'overall' from mx_sched) in ('FAIL', 'INCOMPLETE') and exists (select 1 from private.aios_audit_verification_runs where kind = 'scheduled' and organization_id is null), 'scheduled verification records a global run and never raises');

select 'MXTOTAL|' || last_value || '|checks executed (each emitted a MXRES notice; any failure aborted the script)' from mx.cnt;
rollback;
