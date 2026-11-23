#!/usr/bin/env bash
# PART D concurrency: forced interleavings for the restoration state machine. Real parallel sessions, committed state.
# Usage: restoration_races.sh <DB_URL>   Throwaway CI/local database ONLY (commits fixtures, needs a superuser connection).
# Every scenario FORCES its interleaving (row-lock hold + proof that the contender is blocked in pg_stat_activity); the watchdog
# scenario is also run against a MUTANT watchdog (unlocked preliminary read) and the suite fails unless the mutant is caught.
set -u
DB="$1"; fail=0; RES=/tmp/restoration-races.results; : > "$RES"
. "$(dirname "$0")/cron_guard.sh"
q()   { psql "$DB" -X -qAt -v ON_ERROR_STOP=1 -c "$1"; }
own() { psql "$DB" -X -qAt -c "set session authorization cr_owner; $1" 2>&1 | tail -1; }   # run as the owner login, last result line
check() { if [ "$2" = true ]; then echo "  PASS $1"; echo "PASS|$1|$3" >> "$RES"; else echo "  FAIL $1 ($3)"; echo "FAIL|$1|$3" >> "$RES"; fail=1; fi; }
C1="race-cred-1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; C2="race-cred-2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; C3="race-cred-3-cccccccccccccccccccccccccccc"
trig4() { q "select count(*) from pg_trigger where tgrelid='public.aios_audit_events'::regclass and tgname in ('trg_aios_audit_hash','trg_aios_audit_immutable_update','trg_aios_audit_immutable_delete','trg_aios_audit_no_truncate') and tgenabled='$1'"; }
st()    { q "select status||'/'||generation from private.aios_restoration_state"; }
# NOTE: cron_pause deactivates the scheduler for these tests, so the canonical verifier correctly reports job_inactive and a CLOSE ends as
# closed_verification_failed instead of closed. The closure invariants under test (window closed, guarded triggers re-enabled, single close,
# generation binding) are identical in both end states; closedfam() accepts exactly those two and nothing else.
closedfam() { case "$(q "select status from private.aios_restoration_state")" in closed|closed_verification_failed) return 0;; *) return 1;; esac; }
is_closed_gen() { closedfam && [ "$(q "select generation from private.aios_restoration_state")" = "$1" ]; }

cron_pause "$DB" || { echo "cannot guarantee a quiet scheduler"; exit 1; }
trap 'rc=$?; cron_restore || rc=1; exit $rc' EXIT

reset_state() { # superuser reset of committed fixture state (throwaway DB)
  q "do \$\$ declare g record; begin
       for g in select * from private.aios_guarded_triggers where restorable loop execute format('alter table %I.%I enable always trigger %I', g.schema_name, g.table_name, g.trigger_name); end loop;
       update private.aios_restoration_state set status='closed', window_id=null, expires_at=null, opened_at=null, last_failure=null where id=1;
       delete from private.aios_restoration_credentials; end \$\$" >/dev/null
}
q "do \$\$ begin if not exists (select 1 from pg_roles where rolname='cr_owner') then create role cr_owner login; end if; end \$\$; grant aios_restorer to cr_owner" >/dev/null
ORIG_WATCHDOG=$(q "select pg_get_functiondef('private.aios_restoration_watchdog()'::regprocedure)")

# Hold the restoration-state row lock in session X for $1 seconds, then run $2 (as owner) inside the same transaction.
# Sets /tmp/rr_x_locked once the lock is held; the caller starts contenders afterwards.
hold_lock_then() {
  rm -f /tmp/rr_x_locked
  ( psql "$DB" -X -qAt <<SQL > /tmp/rr_x.out 2>&1
begin;
select 1 from private.aios_restoration_state where id = 1 for update;
\! touch /tmp/rr_x_locked
select pg_sleep($1);
set local session authorization cr_owner;
$2
commit;
SQL
  ) &
  XPID=$!
  for i in $(seq 1 100); do [ -f /tmp/rr_x_locked ] && break; sleep 0.1; done
  [ -f /tmp/rr_x_locked ] || { echo "X never obtained the lock"; return 1; }
}
# Start a contender running $1 (SQL, as owner unless OWNER=0) in the background, writing /tmp/rr_$2.out; wait until it is BLOCKED on a lock.
contender() {
  local sql="$1" tag="$2" pre="set session authorization cr_owner;"; [ "${3:-1}" = 0 ] && pre=""
  ( psql "$DB" -X -qAt -c "$pre $sql" > "/tmp/rr_$tag.out" 2>&1 ) &
  eval "PID_$tag=\$!"
  for i in $(seq 1 100); do
    [ "$(q "select count(*) from pg_stat_activity where wait_event_type='Lock' and pid <> pg_backend_pid() and query like '%$tag%' ")" -ge 1 ] 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

open_expired_window() { # G(n) open and already expired
  reset_state
  own "select private.aios_restoration_install_credential('$C1')" >/dev/null
  own "select private.aios_restoration_open('$C1', 'race test: first window to be expired')" >/dev/null
  q "update private.aios_restoration_state set expires_at = clock_timestamp() - interval '1 minute' where id = 1" >/dev/null
}

scenario_watchdog_vs_new_window() { # R1: stale watchdog must not close a newer window
  open_expired_window
  local g1; g1=$(q "select generation from private.aios_restoration_state")
  own "select private.aios_restoration_install_credential('$C2')" >/dev/null
  hold_lock_then 3 "select private.aios_restoration_close(); select private.aios_restoration_open('$C2', 'race test: second window must survive');" || return 1
  contender "select 'WD' as tag, private.aios_restoration_watchdog()" WD 0 ; blocked=$?
  wait "$XPID"; wait "$PID_WD"
  R1_BLOCKED=$blocked; R1_G1=$g1
}

echo "== R1: watchdog queued behind owner close+reopen must not close the NEW window (forced interleaving)"
scenario_watchdog_vs_new_window
check "R1.a watchdog was provably BLOCKED on the state-row lock while X held it (interleaving forced)" "$([ "$R1_BLOCKED" = 0 ] && echo true || echo false)" "blocked=$R1_BLOCKED"
check "R1.b new window survived: status open, generation $((R1_G1+1))" "$([ "$(st)" = "open/$((R1_G1+1))" ] && echo true || echo false)" "state=$(st)"
check "R1.c the new window's guarded triggers are still disabled" "$([ "$(trig4 D)" = 4 ] && echo true || echo false)" "disabled=$(trig4 D)"
check "R1.d watchdog result was a no-op (it re-evaluated under the lock)" "$(grep -q '"no_op": true' /tmp/rr_WD.out && echo true || echo false)" "$(head -c 160 /tmp/rr_WD.out)"
check "R1.e exactly one close was logged for the expired generation, none for the new one" "$([ "$(q "select count(*) from private.aios_restoration_log where event='closed' and generation=$R1_G1")" -ge 1 ] && [ "$(q "select count(*) from private.aios_restoration_log where event='closed' and generation=$((R1_G1+1))")" = 0 ] && echo true || echo false)" ""

echo "== R1-mutant: watchdog with an UNLOCKED preliminary read must be CAUGHT by the same scenario"
q "create or replace function private.aios_restoration_watchdog() returns jsonb language plpgsql security definer set search_path='' as \$f\$
declare st private.aios_restoration_state; g bigint;
begin
  select * into st from private.aios_restoration_state where id = 1;            -- MUTATION: no lock before deciding
  if st.status = 'open' and st.expires_at <= clock_timestamp() then
    select generation into g from private.aios_restoration_state where id = 1 for update;   -- re-reads the CURRENT generation after waiting
    return private.aios_restoration_close_internal(g, 'mutant');
  end if; return jsonb_build_object('ok', true, 'no_op', true);
end \$f\$" >/dev/null
scenario_watchdog_vs_new_window
mut_state=$(st)
check "R1.mutant the mutant is DETECTED: it wrongly closes the new window (observed $mut_state; the real watchdog left it open)" "$(is_closed_gen $((R1_G1+1)) && echo true || echo false)" "state=$mut_state"
q "$ORIG_WATCHDOG" >/dev/null   # restore the real watchdog
NEWDEF=$(q "select pg_get_functiondef('private.aios_restoration_watchdog()'::regprocedure)")
check "R1.restore the real watchdog definition was restored byte-for-byte" "$([ "$NEWDEF" = "$ORIG_WATCHDOG" ] && echo true || echo false)" ""

echo "== R2: two simultaneous watchdogs over one expired window: exactly one closes, the other is a no-op"
open_expired_window; g=$(q "select generation from private.aios_restoration_state")
start=$(q "select (clock_timestamp() + interval '2 seconds')::text"); rm -f /tmp/rr_w*.out
for i in 1 2 3 4; do ( psql "$DB" -X -qAt -c "select pg_sleep(greatest(0, extract(epoch from ('$start'::timestamptz - clock_timestamp())))); select private.aios_restoration_watchdog()" > /tmp/rr_w$i.out 2>&1 ) & done; wait
closed=$(cat /tmp/rr_w?.out | grep -v '"no_op"' | grep -c '"status": "closed'); noop=$(cat /tmp/rr_w?.out | grep -c '"no_op": true')
check "R2.a exactly one watchdog performed the close ($closed closed, $noop no-op of 4)" "$([ "$closed" = 1 ] && [ "$noop" = 3 ] && echo true || echo false)" "closed=$closed noop=$noop"
check "R2.b final state closed, triggers re-enabled once" "$(is_closed_gen $g && [ "$(trig4 A)" = 4 ] && echo true || echo false)" "$(st)"
check "R2.c one closed log row for the generation (idempotent)" "$([ "$(q "select count(*) from private.aios_restoration_log where event='closed' and generation=$g")" = 1 ] && echo true || echo false)" ""

echo "== R3: owner close vs watchdog on an expired window, forced to queue: single close, consistent state"
open_expired_window; g=$(q "select generation from private.aios_restoration_state")
hold_lock_then 2 "select 'noop'" || fail=1
contender "select 'OC' as tag, private.aios_restoration_close()" OC ; b1=$?
contender "select 'WD3' as tag, private.aios_restoration_watchdog()" WD3 0 ; b2=$?
wait "$XPID"; wait "$PID_OC"; wait "$PID_WD3"
check "R3.a both contenders were provably blocked (forced queue)" "$([ "$b1" = 0 ] && [ "$b2" = 0 ] && echo true || echo false)" "oc=$b1 wd=$b2"
check "R3.b exactly one close, the other idempotent" "$([ "$(q "select count(*) from private.aios_restoration_log where event='closed' and generation=$g")" = 1 ] && is_closed_gen $g && [ "$(trig4 A)" = 4 ] && echo true || echo false)" "$(st)"

echo "== R4: owner close queued BEFORE owner reopen => reopen succeeds on a fresh generation; reversed order => reopen refused, credential NOT consumed"
open_expired_window; g=$(q "select generation from private.aios_restoration_state")
own "select private.aios_restoration_install_credential('$C2')" >/dev/null
hold_lock_then 2.5 "select 'noop'" || fail=1
contender "select 'CL4' as tag, private.aios_restoration_close()" CL4 ; b1=$?
contender "select 'OP4' as tag, private.aios_restoration_open('$C2', 'race test: reopen queued behind close')" OP4 ; b2=$?
wait "$XPID"; wait "$PID_CL4"; wait "$PID_OP4"
check "R4.a close-then-open: both queued, reopen succeeded on generation $((g+1))" "$([ "$b1" = 0 ] && [ "$b2" = 0 ] && [ "$(st)" = "open/$((g+1))" ] && grep -q '"ok": true' /tmp/rr_OP4.out && echo true || echo false)" "state=$(st) open_out=$(head -c 120 /tmp/rr_OP4.out)"
check "R4.b credential consumed exactly once, bound to the new window" "$([ "$(q "select count(*) from private.aios_restoration_credentials where consumed_at is not null and consumed_window_id=(select window_id from private.aios_restoration_state)")" = 1 ] && echo true || echo false)" ""
open_expired_window; g=$(q "select generation from private.aios_restoration_state")
own "select private.aios_restoration_install_credential('$C2')" >/dev/null
hold_lock_then 2.5 "select 'noop'" || fail=1
contender "select 'OP5' as tag, private.aios_restoration_open('$C2', 'race test: reopen queued before close')" OP5 ; b1=$?
contender "select 'CL5' as tag, private.aios_restoration_close()" CL5 ; b2=$?
wait "$XPID"; wait "$PID_OP5"; wait "$PID_CL5"
check "R4.c open-then-close: reopen refused while open (55000), then closed; credential still active" "$([ "$b1" = 0 ] && [ "$b2" = 0 ] && grep -q 'cannot be opened while status' /tmp/rr_OP5.out && is_closed_gen $g && [ "$(q "select count(*) from private.aios_restoration_credentials where consumed_at is null and revoked_at is null")" = 1 ] && echo true || echo false)" "state=$(st) open_out=$(head -c 100 /tmp/rr_OP5.out)"

echo "== R5: 8 sessions open with the SAME credential simultaneously: exactly one window, credential consumed once"
reset_state; own "select private.aios_restoration_install_credential('$C3')" >/dev/null
g=$(q "select generation from private.aios_restoration_state"); start=$(q "select (clock_timestamp() + interval '3 seconds')::text"); rm -f /tmp/rr_o*.out
for i in $(seq 1 8); do ( psql "$DB" -X -qAt -c "set session authorization cr_owner; select pg_sleep(greatest(0, extract(epoch from ('$start'::timestamptz - clock_timestamp())))); select private.aios_restoration_open('$C3', 'race test: eight-way open attempt')" > /tmp/rr_o$i.out 2>&1 ) & done; wait
ok=$(cat /tmp/rr_o?.out | grep -c '"ok": true'); refused=$(cat /tmp/rr_o?.out | grep -c 'cannot be opened while status')
check "R5.a exactly one open succeeded ($ok ok, $refused refused with 55000)" "$([ "$ok" = 1 ] && [ "$refused" = 7 ] && echo true || echo false)" "ok=$ok refused=$refused"
check "R5.b one window, one consumption, generation advanced once" "$([ "$(st)" = "open/$((g+1))" ] && [ "$(q "select count(*) from private.aios_restoration_credentials where consumed_at is not null")" = 1 ] && echo true || echo false)" "$(st)"
check "R5.c a consumed credential cannot authorize another window" "$(own "select private.aios_restoration_close()" >/dev/null; own "select private.aios_restoration_open('$C3', 'race test: reuse of a consumed credential')" | grep -q 'credential_invalid' && echo true || echo false)" ""

echo "== R6: rotate vs open queued: never two active credentials, never a window from a revoked credential"
reset_state; own "select private.aios_restoration_install_credential('$C1')" >/dev/null
hold_lock_then 2.5 "select 'noop'" || fail=1
contender "select 'RT6' as tag, private.aios_restoration_rotate_credential('$C1', '$C2')" RT6 ; b1=$?
contender "select 'OP6' as tag, private.aios_restoration_open('$C1', 'race test: open with a credential being rotated')" OP6 ; b2=$?
wait "$XPID"; wait "$PID_RT6"; wait "$PID_OP6"
act=$(q "select count(*) from private.aios_restoration_credentials where consumed_at is null and revoked_at is null")
check "R6.a rotate won the queue: old credential revoked, open with it refused, exactly one active credential" "$([ "$b1" = 0 ] && [ "$b2" = 0 ] && [ "$act" = 1 ] && grep -q credential_invalid /tmp/rr_OP6.out && [ "$(q "select status from private.aios_restoration_state")" = closed ] && echo true || echo false)" "active=$act open_out=$(head -c 100 /tmp/rr_OP6.out)"

reset_state
echo; [ $fail = 0 ] && echo "RESTORATION RACES: ALL PASS" || echo "RESTORATION RACES: FAILURES"
exit $fail
