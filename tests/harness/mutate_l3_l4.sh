#!/usr/bin/env bash
# Mutation battery for the L3/L4 lock-order + lock-conflict workstream (throwaway local cluster only; uses replay.sh).
# Each mutation removes ONE guard from migration 20261110100000 in a temp copy; the matching test MUST fail. A control run (no mutation) MUST pass.
# Usage: mutate_l3_l4.sh <DB_NAME> [conninfo]      default conninfo: host=/var/run/postgresql dbname=<DB_NAME> user=postgres
set -u
DBN="${1:?db name}"; CONN="${2:-host=/var/run/postgresql dbname=$DBN user=postgres}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; MIG=supabase/migrations/20261110100000_aios_batch_prelock_before_audit.sql
TMP=$(mktemp -d); chmod 755 "$TMP"; trap 'rm -rf "$TMP"' EXIT; bad=0
run() { # <label> <expect: pass|fail> <sed-expr or ""> <test script>
  rm -rf "$TMP/r"; mkdir -p "$TMP/r"; cp -r "$ROOT/tests" "$ROOT/supabase" "$TMP/r/"; chmod -R a+rX "$TMP/r"
  if [ -n "$3" ]; then sed -i "$3" "$TMP/r/$MIG"; cmp -s "$TMP/r/$MIG" "$ROOT/$MIG" && { echo "  ERROR  $1: mutation did not change the migration"; bad=1; return; }; fi
  bash "$TMP/r/tests/harness/replay.sh" "$DBN" >"$TMP/replay.out" 2>&1 || { echo "  ERROR  $1: replay failed: $(tail -c 300 "$TMP/replay.out")"; bad=1; return; }
  bash "$TMP/r/tests/concurrency/$4" "$CONN" >"$TMP/out" 2>&1; rc=$?
  if [ "$2" = pass ]; then [ $rc = 0 ] && echo "  OK     $1 (control passes)" || { echo "  ERROR  $1: control FAILED (rc=$rc)"; tail -n 8 "$TMP/out"; bad=1; }
  else [ $rc != 0 ] && [ $rc != 2 ] && echo "  KILLED $1 (test failed as it must)" || { echo "  SURVIVED/INVALID $1 (rc=$rc): the test did not detect the mutation"; bad=1; }; fi
}
run "control: expiry forced"            pass ""  l3_audit_lock_forced.sh
run "control: reaper forced"            pass ""  l4_reaper_audit_lock_forced.sh
run "control: lock-conflict deferral"   pass ""  l3_lock_conflict_deferral.sh
run "M1 expiry phase-1 pre-lock removed"   fail 's/^  perform private\.aios_prelock_approvals_batch(v_ids);/  null;/' l3_audit_lock_forced.sh
run "M2 reaper phase-1 pre-lock removed"   fail 's/^  perform private\.aios_prelock_tasks_batch(v_ids);/  null;/'      l4_reaper_audit_lock_forced.sh
run "M3 lock conflicts treated as errors again (swallow reintroduced)" fail "s/select p_sqlstate in (.*/select false/" l3_lock_conflict_deferral.sh
echo "mutation battery: $([ $bad = 0 ] && echo ALL KILLED + CONTROLS PASS || echo PROBLEMS)"; exit $bad
