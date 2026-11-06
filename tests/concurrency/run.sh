#!/usr/bin/env bash
# G4: eight-way concurrency. Eight real parallel database sessions race on each critical path; invariants are asserted from committed state.
# Usage: run.sh <DB_URL>. Local throwaway CI database only.
set -u
DB="$1"; N=8; fail=0
q() { psql "$DB" -At -v ON_ERROR_STOP=1 -c "$1"; }
q "select 1" >/dev/null || { echo "cannot connect"; exit 1; }
# Own the clock: no pg_cron tick may expire fixtures between creation and assertion (see cron_guard.sh).
. "$(dirname "$0")/cron_guard.sh"
cron_pause "$DB" || { echo "G4 cannot guarantee a quiet scheduler"; exit 1; }
trap 'rc=$?; cron_restore || rc=1; exit $rc' EXIT
psql "$DB" -q -v ON_ERROR_STOP=1 -f "$(dirname "$0")/setup.sql" >/dev/null || { echo "G4 fixture setup failed"; exit 1; }

ORG=c1c1c1c1-0000-4000-8000-000000000001; AGENT=c2c2c2c2-0000-4000-8000-000000000001
REQ=00000000-0000-4000-8000-0000000c1001; ADM=00000000-0000-4000-8000-0000000c1002
INV1=c3c3c3c3-0000-4000-8000-000000000001; INV2=c3c3c3c3-0000-4000-8000-000000000002
APR1=$(q "select approval_id from public.aios_tool_invocations where id='$INV1'")

# Launch N workers that all start at the same instant; $1 = SQL template using START as the barrier timestamp.
race() {
  local tpl="$1" start; start=$(q "select (clock_timestamp() + interval '3 seconds')::text")
  rm -f /tmp/cx_*.out
  for i in $(seq 1 $N); do
    psql "$DB" -At -c "${tpl//START/$start}" > /tmp/cx_$i.out 2>&1 &
  done
  wait
  cat /tmp/cx_*.out | sort | uniq -c | sed 's/^ *//' | tr '\n' ';'
}
count() { cat /tmp/cx_*.out | grep -c -x "$1"; }
check() { if [ "$2" = "true" ]; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }

echo "== G4 S1: $N concurrent approvals of one approval"
out=$(race "select cx.resolve('START'::timestamptz, '$APR1', '$ADM')"); echo "  results: $out"
ok=$(count OK); lost=$(count 40001)
check "exactly one approval wins, the rest get 40001 (won=$ok lost=$lost)" "$([ "$ok" = 1 ] && [ "$lost" = $((N-1)) ] && echo true || echo false)"
check "approval resolved once, invocation approved" "$([ "$(q "select (select status from public.aios_approvals where id='$APR1')||'/'||(select status from public.aios_tool_invocations where id='$INV1')")" = "approved/approved" ] && echo true || echo false)"

echo "== G4 S2: $N concurrent execution claims of one approved invocation"
# INV2 is auto-approved at insert (low-risk, in contract)
check "S2 precondition: invocation is approved" "$([ "$(q "select status from public.aios_tool_invocations where id='$INV2'")" = approved ] && echo true || echo false)"
out=$(race "select cx.authz('START'::timestamptz, '$INV2')"); echo "  results: $out"
ok=$(count OK); lost=$(count 40001)
check "exactly one claim wins, the rest get 40001 (won=$ok lost=$lost)" "$([ "$ok" = 1 ] && [ "$lost" = $((N-1)) ] && echo true || echo false)"
check "invocation executing exactly once" "$([ "$(q "select status from public.aios_tool_invocations where id='$INV2'")" = executing ] && [ "$(q "select count(*) from public.aios_audit_events where invocation_id='$INV2' and new_state='executing'")" = 1 ] && echo true || echo false)"

echo "== G4 S3: $N concurrent requests with one idempotency key"
out=$(race "select cx.dup('START'::timestamptz, '$ORG', '$AGENT', 'cx-idem-key', '$REQ')"); echo "  results: $out"
ok=$(count OK); dup=$(count 23505)
check "exactly one row created, the rest get 23505 (created=$ok dup=$dup)" "$([ "$ok" = 1 ] && [ "$dup" = $((N-1)) ] && echo true || echo false)"
check "one invocation row for the key" "$([ "$(q "select count(*) from public.aios_tool_invocations where organization_id='$ORG' and idempotency_key='cx-idem-key'")" = 1 ] && echo true || echo false)"

echo "== G4 S4: $N concurrent runs of the expiry job over 24 lapsed approvals"
pre=$(q "select count(*) from public.aios_approvals where organization_id='$ORG' and status='pending' and expires_at <= now()")
out=$(race "select cx.job('START'::timestamptz)"); echo "  results: $out"
errs=$(cat /tmp/cx_*.out | grep -c '^ERR:')
sum=$(cat /tmp/cx_*.out | grep '^N:' | cut -d: -f2 | paste -sd+ - | bc)
check "no worker errored (errors=$errs)" "$([ "$errs" = 0 ] && echo true || echo false)"
check "each lapsed approval converged exactly once (pre=$pre, summed=$sum)" "$([ "$pre" = 24 ] && [ "$sum" = 24 ] && echo true || echo false)"
check "all 24 approvals and invocations expired, none pending" "$([ "$(q "select count(*) from public.aios_approvals a join public.aios_tool_invocations i on i.approval_id=a.id where a.organization_id='$ORG' and a.status='expired' and i.status='expired'")" = 24 ] && [ "$(q "select count(*) from public.aios_approvals where organization_id='$ORG' and status='pending' and expires_at <= now()")" = 0 ] && echo true || echo false)"
check "each invocation expired exactly once in the audit trail (one approval_changed + one tool_invocation_status_changed each; no duplicates, none missing)" "$([ "$(q "select count(*) from (select invocation_id, event_type from public.aios_audit_events where organization_id='$ORG' and new_state='expired' and invocation_id is not null group by 1,2 having count(*)>1) d")" = 0 ] && [ "$(q "select count(*) from public.aios_audit_events where organization_id='$ORG' and new_state='expired' and event_type='approval_changed'")" = 24 ] && [ "$(q "select count(*) from public.aios_audit_events where organization_id='$ORG' and new_state='expired' and event_type='tool_invocation_status_changed'")" = 24 ] && echo true || echo false)"
check "audit chain still valid after the races" "$([ "$(q "select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false); select (private.verify_audit_chain('$ORG'))->>'valid'" | tail -1)" = true ] && echo true || echo false)"

if [ $fail -eq 0 ]; then echo "ok: G4 eight-way concurrency"; else echo "G4 FAILED"; exit 1; fi
