#!/usr/bin/env bash
# Generates tests/golden/audit-golden-vectors.json from the REAL append trigger (private.aios_audit_append, migration 20260825123422).
# `expected_payload` is computed by an inline copy of the historical expression (NOT by the Part E canonical function), so the file
# is an independent reference for: the SQL canonical functions (tests/sql/13) and the Python external verifier (tests/external).
# Usage: generate_audit_golden.sh <psql-conn-args...>   (runs inside a rolled-back transaction on a throwaway DB)
set -euo pipefail
OUT="$(dirname "$0")/audit-golden-vectors.json"
psql "$@" -X -qAt <<'SQL' > "$OUT"
begin;
set local timezone = 'UTC';
insert into public.aios_organizations (id, name) values ('0a0a0a0a-0000-4000-8000-00000000601d', 'golden-a'), ('0a0a0a0a-0000-4000-8000-00000000602d', 'golden-b');
create temp table g_in (n int, org uuid, id uuid, event_type text, tool_name text, previous_state text, new_state text, arguments_hash text, risk text, created_at timestamptz, metadata jsonb);
insert into g_in values
 (1, '0a0a0a0a-0000-4000-8000-00000000601d', '00000000-0000-4000-8000-000000000001', 'golden.basic', null, null, null, null, 'low', '2026-01-01 00:00:00+00', '{}'),
 (2, '0a0a0a0a-0000-4000-8000-00000000601d', '00000000-0000-4000-8000-000000000002', 'golden.unicode', '', 'a', 'b', 'abc', 'high', '2026-01-01 00:00:00.120000+00',
    '{"k":"héllo 世界 😀 \u0001 tab\t quote\" back\\ ","n":[1,2.50,null,true,false],"z":{"b":1,"a":{"c":"x"},"empty":{},"arr":[]}}'),
 (3, '0a0a0a0a-0000-4000-8000-00000000601d', '00000000-0000-4000-8000-000000000003', 'golden.collision', 'tool', null, null, null, 'low', '2026-01-01 00:00:00.120000+00',
    '{"big":12345678901234567890.123456789,"neg":-0.000001,"exp":1e3,"zero":0.0,"s":""}'),
 (4, '0a0a0a0a-0000-4000-8000-00000000601d', '00000000-0000-4000-8000-000000000004', 'golden.boundary', 'tool', null, null, null, 'critical', '2038-01-19 03:14:07.999999+00', '{"d":{"d":{"d":{"d":"deep"}}}}'),
 (5, '0a0a0a0a-0000-4000-8000-00000000602d', '00000000-0000-4000-8000-000000000005', 'golden.second-org', null, null, null, null, 'low', '2026-01-01 00:00:00+00', '{"org":"b"}');
insert into public.aios_audit_events (id, organization_id, event_type, tool_name, previous_state, new_state, arguments_hash, risk_level, created_at, metadata)
  select id, org, event_type, tool_name, previous_state, new_state, arguments_hash, risk, created_at, metadata from g_in order by n;
select jsonb_pretty(jsonb_build_object(
  'description', 'Golden vectors from the real aios_audit_append trigger. expected_payload = historical expression (previous_event_hash included in the JSON AND appended again).',
  'algorithm_version', 'aios-audit-sha256-v1',
  'vectors', (select jsonb_agg(v order by org, seq) from (
     select e.organization_id::text as org, row_number() over (partition by e.organization_id order by e.created_at, e.id) as seq,
       jsonb_build_object(
         'organization_id', e.organization_id, 'seq', row_number() over (partition by e.organization_id order by e.created_at, e.id),
         'event', to_jsonb(e) - 'request_id',
         'created_at_canonical', to_jsonb(e.created_at) #>> '{}',
         'expected_payload', jsonb_build_object('id',e.id,'organization_id',e.organization_id,'actor_user_id',e.actor_user_id,'actor_type',e.actor_type,'agent_id',e.agent_id,'mission_id',e.mission_id,'task_id',e.task_id,'invocation_id',e.invocation_id,'event_type',e.event_type,'previous_state',e.previous_state,'new_state',e.new_state,'tool_name',e.tool_name,'risk_level',e.risk_level,'arguments_hash',e.arguments_hash,'result_hash',e.result_hash,'approval_id',e.approval_id,'created_at',e.created_at,'metadata',e.metadata,'previous_event_hash',e.previous_event_hash)::text || e.previous_event_hash,
         'expected_event_hash', e.event_hash) as v
     from public.aios_audit_events e where e.organization_id in ('0a0a0a0a-0000-4000-8000-00000000601d', '0a0a0a0a-0000-4000-8000-00000000602d')) q)));
rollback;
SQL
echo "wrote $OUT"
