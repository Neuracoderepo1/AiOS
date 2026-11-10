#!/usr/bin/env bash
# End-to-end external verification round trip. Usage: e2e.sh <psql conn args...>   (superuser; rolled-back transactions only; needs openssl + git + python3)
# 1. SQL: deterministic fixture -> bounded export pages + DB checkpoint digests   2. python: build artifacts (git repo + RFC3161 via a TEST TSA)
# 3. SQL: the DATABASE accepts exactly those artifacts' evidence; dump anchors list   4. python: independent verifier + tamper tests
set -euo pipefail
cd "$(dirname "$0")/../.."
D="${AIOS_E2E_DIR:-$(mktemp -d)}"; export AIOS_E2E_DIR="$D"; mkdir -p "$D/export" "$D/checkpoints"
ORG=e2e00000-0000-4000-8000-0000000000e1
P() { psql "$@" -X -qAt -v ON_ERROR_STOP=1; }
echo "== phase 1: fixture export (rolled back)"
P "$@" -v D="$D" <<SQL
begin; set constraints all immediate;
\i tests/external/fixture_events.sql
\o /dev/null
\set ON_ERROR_STOP on
\o
select private.aios_audit_chain_export('$ORG', 0, 5) \g $D/export/$ORG.page-1.json
select private.aios_audit_chain_export('$ORG', 5, 5) \g $D/export/$ORG.page-2.json
select private.aios_audit_chain_export('$ORG', 10, 5) \g $D/export/$ORG.page-3.json
select jsonb_agg(jsonb_build_object('event_count', n, 'head_id', e.id, 'head_hash', e.event_hash, 'head_at', to_jsonb(e.created_at) #>> '{}',
         'digest', private.aios_audit_checkpoint_digest(e.organization_id, n, e.id, e.event_hash, e.created_at),
         'checkpoint_text', private.aios_audit_checkpoint_text(e.organization_id, n, e.id, e.event_hash, e.created_at)) order by n)
  from (select unnest(array[6, 9]) n) x, lateral (select * from public.aios_audit_events where organization_id = '$ORG' order by created_at, id offset x.n - 1 limit 1) e \g $D/digests.json
rollback;
SQL
echo "== phase 2: build external artifacts (TEST_FIXTURE)"
python3 tests/external/build_artifacts.py "$D"
echo "== phase 3: database accepts exactly that evidence (rolled back)"
P "$@" <<SQL
begin; set constraints all immediate;
\i tests/external/fixture_events.sql
\set anchors \`cat $D/anchors_for_db.json\`
create temp table e2e_anchors as select x as a from jsonb_array_elements(:'anchors'::jsonb) x;
select count(*) = 2 and bool_and((private.aios_audit_record_anchor('$ORG', (a ->> 'event_count')::bigint, (a ->> 'head_event_id')::uuid, a ->> 'head_hash', (a ->> 'head_at')::timestamptz,
         a ->> 'evidence_type', a ->> 'artifact_sha256', a ->> 'artifact_ref', a -> 'evidence') ->> 'ok')::boolean) as accepted from e2e_anchors \gset
\if :accepted
\else
\echo 'DATABASE REJECTED THE EXTERNAL EVIDENCE'
select 1/0;
\endif
select private.aios_audit_anchors_list('$ORG') \g $D/export/$ORG.anchors.json
rollback;
SQL
echo "== phase 4: independent verifier + tamper tests"
python3 -m unittest -v tests.external.test_audit_verify 2>&1
