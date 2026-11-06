# shellcheck shell=bash
# Sourced by the concurrency tests (G4 run.sh, expiry_race.sh). Throwaway CI databases only.
#
# Why: the local Supabase stack runs pg_cron, which fires private.aios_expire_stale_approvals() every 5 minutes on the wall clock.
# These tests commit "lapsed" fixtures and then count them. If a cron tick lands between fixture creation and the count, the job
# expires the fixtures first and the test sees pre=0 (observed: CI run 41592205865, G4 S4, at 06:50:03 UTC, a */5 boundary).
# The tests must therefore own the clock: pause every active cron job, wait for any in-flight run, fail closed if that cannot be
# proven, and restore the scheduler to exactly its original state on exit.
#
# Contract
#   cron_pause <DB_URL>  Snapshots EVERY cron job (id + active flag), installs the EXIT handler, and only then deactivates the
#                        active jobs. Returns non-zero (after restoring) unless no cron job can fire during the test.
#                        The caller must NOT install its own EXIT trap; this file owns it. Call from the main shell, never
#                        inside $(...) or a pipeline, or the trap is installed in a subshell and never fires.
#   cron_restore         Idempotent. Compares live state to the snapshot, reports unexpected changes, sets every snapshot job
#                        back to its ORIGINAL flag (active stays active, inactive stays inactive), never enables a job that is
#                        not in the snapshot, then re-reads and verifies. Non-zero if anything cannot be verified.
#   Exit status          rc of the test body is preserved when non-zero. If the body passed (0) but cleanup failed, the guard
#                        exits CRON_GUARD_CLEANUP_RC (70) so a green test can never hide a failed or unverified restoration.
CRON_GUARD_CLEANUP_RC=70
CRON_GUARD_DB=""; CRON_GUARD_SNAPSHOT=""; CRON_GUARD_STATE="idle"   # idle | armed | done

_cg_sql() { psql "$CRON_GUARD_DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }

# Whole scheduler state: "jobid:t jobid:f ..." for every job, active or not.
_cg_snapshot() { _cg_sql "select coalesce(string_agg(jobid::text || ':' || active::text, ' ' order by jobid), '') from cron.job"; }

# $1 = list "id:flag ...", $2 = job id  ->  prints t | f | (nothing when absent)
_cg_flag() { printf '%s\n' "$1" | tr ' ' '\n' | awk -F: -v id="$2" '$1 == id { print $2 }'; }
_cg_ids()  { printf '%s\n' "$1" | tr ' ' '\n' | awk -F: 'NF { print $1 }'; }

_cg_set_one() { # $1 = job id, $2 = true|false
  if [ "$(_cg_sql "select to_regprocedure('cron.alter_job(bigint,text,text,text,text,boolean)') is not null")" = t ]; then
    _cg_sql "select cron.alter_job($1, active := $2)" >/dev/null
  else
    _cg_sql "update cron.job set active = $2 where jobid = $1" >/dev/null
  fi
}

_cg_set_one_retry() { local n; for n in 1 2 3; do _cg_set_one "$1" "$2" && return 0; sleep 0.2; done; return 1; }

_cg_in_flight() { _cg_sql "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and state <> 'idle' and (application_name = 'pg_cron' or query ~* 'aios_(expire_stale_approvals|reap_stale_tasks)')"; }

cron_pause() {
  if [ "$CRON_GUARD_STATE" = armed ]; then echo "cron guard: already armed (nested cron_pause is not supported)"; return 1; fi
  CRON_GUARD_DB="$1"; CRON_GUARD_SNAPSHOT=""; CRON_GUARD_STATE="idle"
  local has; has=$(_cg_sql "select to_regclass('cron.job') is not null") || { echo "cron guard: cannot query the database"; return 1; }
  if [ "$has" != t ]; then echo "== cron: pg_cron not installed, nothing to pause"; return 0; fi

  # 1. Capture original state BEFORE any mutation. Without a trustworthy snapshot we cannot restore, so we do not start.
  CRON_GUARD_SNAPSHOT=$(_cg_snapshot) || { echo "cron guard: cannot read cron.job, nothing was changed"; CRON_GUARD_SNAPSHOT=""; return 1; }

  # 2. Arm cleanup BEFORE the first deactivation, so a half-finished pause is always restored.
  CRON_GUARD_STATE="armed"
  trap '_cg_on_exit' EXIT

  # 3. Pause. A failure part-way is safe: restore is driven by the snapshot, not by what we managed to change.
  local pair id
  for pair in $CRON_GUARD_SNAPSHOT; do
    [ "${pair#*:}" = t ] || continue
    id=${pair%%:*}
    _cg_set_one "$id" false || { echo "cron guard: cannot deactivate cron job $id (partial pause), restoring"; cron_restore; return 1; }
  done

  # 4. Verify isolation instead of assuming it.
  local active; active=$(_cg_sql "select count(*) from cron.job where active") || { echo "cron guard: cannot verify pause, restoring"; cron_restore; return 1; }
  [ "$active" = 0 ] || { echo "cron guard: jobs still active after pause, restoring"; cron_restore; return 1; }

  # A tick that started before the pause may still be running: wait until none is, at most 60s.
  local i n=1
  for i in $(seq 1 120); do
    n=$(_cg_in_flight) || { echo "cron guard: cannot inspect running jobs, restoring"; cron_restore; return 1; }
    [ "$n" = 0 ] && break
    sleep 0.5
  done
  [ "$n" = 0 ] || { echo "cron guard: a cron run is still in flight after 60s, restoring"; cron_restore; return 1; }
  echo "== cron: paused jobs [$(printf '%s' "$CRON_GUARD_SNAPSHOT" | tr ' ' '\n' | awk -F: '$2=="t"{printf "%s ", $1}' | sed 's/ $//')], no run in flight (restored on exit)"
}

cron_restore() {
  [ "$CRON_GUARD_STATE" = armed ] || return 0        # idempotent: never restore twice, never restore what was never armed
  CRON_GUARD_STATE="done"                            # set first so a re-entrant trap/call cannot run a second restoration
  local fail=0 cur pair id orig now
  cur=$(_cg_snapshot) || { echo "cron guard: cannot read cron.job to restore, state UNVERIFIED"; return 1; }

  # Detect unexpected scheduler changes made while we owned the clock.
  for pair in $CRON_GUARD_SNAPSHOT; do
    id=${pair%%:*}; orig=${pair#*:}; now=$(_cg_flag "$cur" "$id")
    if [ -z "$now" ]; then echo "cron guard: UNEXPECTED job $id (originally active=$orig) no longer exists"; fail=1
    elif [ "$now" = t ]; then echo "cron guard: UNEXPECTED job $id became active during isolation (originally active=$orig); isolation was compromised"; fail=1
    fi
  done
  for id in $(_cg_ids "$cur"); do
    if [ -z "$(_cg_flag "$CRON_GUARD_SNAPSHOT" "$id")" ]; then
      echo "cron guard: UNEXPECTED job $id appeared during isolation (active=$(_cg_flag "$cur" "$id")); left untouched, not enabled"
      [ "$(_cg_flag "$cur" "$id")" = t ] && fail=1
    fi
  done

  # Restore every snapshot job to its ORIGINAL flag. Keep going after a failure so one bad job cannot strand the others.
  for pair in $CRON_GUARD_SNAPSHOT; do
    id=${pair%%:*}; orig=${pair#*:}; now=$(_cg_flag "$cur" "$id")
    [ -n "$now" ] || continue
    [ "$now" = "$orig" ] && continue
    if [ "$orig" = t ]; then _cg_set_one_retry "$id" true || { echo "cron guard: FAILED to re-activate job $id"; fail=1; }
    else _cg_set_one_retry "$id" false || { echo "cron guard: FAILED to deactivate job $id (originally inactive)"; fail=1; }
    fi
  done

  # Verify rather than assume.
  cur=$(_cg_snapshot) || { echo "cron guard: cannot re-read cron.job after restore, state UNVERIFIED"; return 1; }
  for pair in $CRON_GUARD_SNAPSHOT; do
    id=${pair%%:*}; orig=${pair#*:}; now=$(_cg_flag "$cur" "$id")
    [ "$now" = "$orig" ] || { echo "cron guard: job $id is active=${now:-missing} after restore, expected $orig"; fail=1; }
  done
  [ "$fail" = 0 ] && echo "== cron: restored scheduler to original state [$CRON_GUARD_SNAPSHOT], verified"
  return "$fail"
}

_cg_on_exit() {
  local rc=$? crc=0
  trap - EXIT
  cron_restore || crc=$?
  if [ "$crc" != 0 ]; then
    echo "cron guard: CLEANUP FAILED (cleanup rc=$crc, test rc=$rc)"
    [ "$rc" = 0 ] && rc=$CRON_GUARD_CLEANUP_RC          # never let a passing test hide failed restoration
  fi
  exit "$rc"
}
