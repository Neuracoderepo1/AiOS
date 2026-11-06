#!/usr/bin/env bash
# Regression tests for tests/concurrency/cron_guard.sh using a fake psql (no database needed).  Usage: bash tests/concurrency/test_cron_guard.sh
HERE="$(cd "$(dirname "$0")" && pwd)"; pass=0; failn=0
ok()  { pass=$((pass+1)); echo "  ok   - $1"; }
bad() { failn=$((failn+1)); echo "  FAIL - $1 (got: $2)"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "'$2' expected '$3'"; }

# run <initial jobs "1 t;2 t;3 f"> <body> [env...]  -> sets RC, OUT, FINAL (final "id:flag ..." state), UPD (update count)
run() {
  local jobs="$1" body="$2"; shift 2
  SHIM_DIR=$(mktemp -d); printf '%s\n' "${jobs//;/$'\n'}" > "$SHIM_DIR/jobs"; : > "$SHIM_DIR/updates.log"
  mkdir -p "$SHIM_DIR/bin"; cp "$HERE/cron_guard_test/fake_psql" "$SHIM_DIR/bin/psql"
  OUT=$(env SHIM_DIR="$SHIM_DIR" PATH="$SHIM_DIR/bin:$PATH" "$@" bash -c '
    . "'"$HERE"'/cron_guard.sh"
    shim_set() { sed -i "s/^$1 .*/$1 $2/" "$SHIM_DIR/jobs"; }
    shim_add() { echo "$1 $2" >> "$SHIM_DIR/jobs"; }
    active_now() { awk "\$2==\"t\"{n++} END{print n+0}" "$SHIM_DIR/jobs"; }
    '"$body" 2>&1); RC=$?
  FINAL=$(awk '{printf "%s%s:%s",(NR>1?" ":""),$1,$2}' "$SHIM_DIR/jobs"); UPD=$(wc -l < "$SHIM_DIR/updates.log")
}

echo "1. successful pause and restoration"
run "1 t;2 t;3 f" 'cron_pause x || exit 1; echo "ACTIVE_DURING=$(active_now)"; exit 0'
eq "exit 0" "$RC" 0; eq "scheduler quiet during test" "$(grep -o 'ACTIVE_DURING=.*' <<<"$OUT")" "ACTIVE_DURING=0"; eq "state restored" "$FINAL" "1:t 2:t 3:f"
echo "2. partial pause failure is still restored"
run "1 t;2 t;3 f" 'cron_pause x || exit 1; exit 0' SHIM_FAIL_DEACT=2
eq "pause reported failure (nonzero)" "$([ $RC -ne 0 ] && echo nz)" nz; eq "job 1 re-activated" "$FINAL" "1:t 2:t 3:f"
echo "3. restoration failure"
run "1 t;2 t;3 f" 'cron_pause x || exit 1; exit 0' SHIM_FAIL_ACT=2
eq "passing test + failed cleanup => 70" "$RC" 70; grep -q "FAILED to re-activate job 2" <<<"$OUT" && ok "failure reported" || bad "failure reported" "$OUT"
eq "job 1 still restored despite job 2 failing" "$(awk -F: '{print $0}' <<<"$FINAL" | grep -o '1:t')" "1:t"
echo "4. originally inactive jobs stay inactive"
run "1 t;2 f;3 f" 'cron_pause x || exit 1; exit 0'
eq "inactive jobs untouched" "$FINAL" "1:t 2:f 3:f"; eq "only the active job was ever written (2 updates: pause+restore)" "$UPD" 2
run "1 t;2 f" 'cron_pause x || exit 1; shim_set 2 t; exit 0'
eq "inactive job enabled mid-test is detected (nonzero)" "$RC" 70; eq "and forced back to inactive" "$FINAL" "1:t 2:f"
echo "5. unexpected scheduler-state change"
run "1 t" 'cron_pause x || exit 1; shim_add 9 t; exit 0'
eq "new active job => nonzero" "$RC" 70; grep -q "job 9 appeared" <<<"$OUT" && ok "reported" || bad "reported" "$OUT"; eq "new job NOT auto-enabled/changed" "$FINAL" "1:t 9:t"
run "1 t" 'cron_pause x || exit 1; shim_add 9 f; exit 0'
eq "new inactive job tolerated, left inactive" "$RC:$FINAL" "0:1:t 9:f"
run "1 t" 'cron_pause x || exit 1; shim_set 1 t; exit 0'
eq "job re-activated during isolation => nonzero" "$RC" 70
echo "6. original test exit code preserved"
run "1 t;2 f" 'cron_pause x || exit 1; exit 7'
eq "rc 7 preserved" "$RC" 7; eq "restored" "$FINAL" "1:t 2:f"
run "1 t;2 t" 'cron_pause x || exit 1; exit 7' SHIM_FAIL_ACT=1
eq "failing test + failed cleanup keeps rc 7" "$RC" 7; grep -q "CLEANUP FAILED" <<<"$OUT" && ok "cleanup failure still reported" || bad "cleanup failure still reported" "$OUT"
echo "7. idempotence / no repeated restoration"
run "1 t;2 f" 'cron_pause x || exit 1; cron_restore; cron_restore; exit 0'
eq "exit 0" "$RC" 0; eq "exactly pause+restore writes (EXIT trap did not restore again)" "$UPD" 2
echo "8. fail closed"
run "1 t" 'cron_pause x || exit 1; exit 0' SHIM_FAIL_SNAPSHOT=1
eq "unreadable snapshot => nonzero, nothing mutated" "$RC:$UPD:$FINAL" "1:0:1:t"
run "1 t" 'cron_pause x || exit 1; exit 0' SHIM_NO_CRON=1
eq "no pg_cron => pass, nothing touched" "$RC:$UPD" "0:0"

echo; echo "cron_guard tests: $pass passed, $failn failed"; [ "$failn" = 0 ]
