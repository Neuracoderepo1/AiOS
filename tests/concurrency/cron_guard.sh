# shellcheck shell=bash
# Sourced by the concurrency tests (G4 run.sh, expiry_race.sh). Throwaway CI databases only.
#
# Why: the local Supabase stack runs pg_cron, which fires private.aios_expire_stale_approvals() every 5 minutes on the wall clock.
# These tests commit "lapsed" fixtures and then count them. If a cron tick lands between fixture creation and the count, the job
# expires the fixtures first and the test sees pre=0 (observed: CI run 41592205865, G4 S4, at 06:50:03 UTC, a */5 boundary).
# The tests must therefore own the clock: pause every active cron job, wait for any in-flight run, fail closed if that cannot be
# proven, and restore exactly the jobs that were active on exit.
#   cron_pause <DB_URL>   returns non-zero (and prints why) unless no cron job can fire during the test
#   cron_restore          re-activates the jobs cron_pause deactivated; non-zero if the active set differs afterwards
CRON_GUARD_DB=""; CRON_GUARD_IDS=""

_cg_sql() { psql "$CRON_GUARD_DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }

_cg_set_active() { # $1 = true|false, $2 = space separated job ids
  local id
  for id in $2; do
    if [ "$(_cg_sql "select to_regprocedure('cron.alter_job(bigint,text,text,text,text,boolean)') is not null")" = t ]; then
      _cg_sql "select cron.alter_job($id, active := $1)" >/dev/null || return 1
    else
      _cg_sql "update cron.job set active = $1 where jobid = $id" >/dev/null || return 1
    fi
  done
}

cron_pause() {
  CRON_GUARD_DB="$1"
  if [ "$(_cg_sql "select to_regclass('cron.job') is not null")" != t ]; then
    CRON_GUARD_IDS=""; echo "== cron: pg_cron not installed, nothing to pause"; return 0
  fi
  CRON_GUARD_IDS=$(_cg_sql "select coalesce(string_agg(jobid::text, ' ' order by jobid), '') from cron.job where active") || { echo "cron guard: cannot read cron.job"; return 1; }
  _cg_set_active false "$CRON_GUARD_IDS" || { echo "cron guard: cannot deactivate cron jobs"; return 1; }
  [ "$(_cg_sql "select count(*) from cron.job where active")" = 0 ] || { echo "cron guard: jobs still active after pause"; return 1; }
  # A tick that started before the pause may still be running: wait until none is, at most 60s.
  local i
  for i in $(seq 1 120); do
    [ "$(_cg_sql "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and state <> 'idle' and (application_name = 'pg_cron' or query ~* 'aios_(expire_stale_approvals|reap_stale_tasks)')")" = 0 ] && break
    sleep 0.5
  done
  [ "$(_cg_sql "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and state <> 'idle' and (application_name = 'pg_cron' or query ~* 'aios_(expire_stale_approvals|reap_stale_tasks)')")" = 0 ] || { echo "cron guard: a cron run is still in flight after 60s"; return 1; }
  echo "== cron: paused jobs [${CRON_GUARD_IDS:-none}], no run in flight (restored on exit)"
}

cron_restore() {
  [ -n "$CRON_GUARD_DB" ] || return 0
  if [ -n "$CRON_GUARD_IDS" ]; then
    _cg_set_active true "$CRON_GUARD_IDS" || { echo "cron guard: FAILED to restore cron jobs [$CRON_GUARD_IDS]"; return 1; }
    local now; now=$(_cg_sql "select coalesce(string_agg(jobid::text, ' ' order by jobid), '') from cron.job where active")
    [ "$now" = "$CRON_GUARD_IDS" ] || { echo "cron guard: active set after restore [$now] differs from before [$CRON_GUARD_IDS]"; return 1; }
    echo "== cron: restored jobs [$CRON_GUARD_IDS]"
  fi
}
