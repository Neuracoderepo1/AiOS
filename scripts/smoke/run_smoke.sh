#!/usr/bin/env bash
# AiOS read-only smoke runner.
#
# Credentials (never put them on the command line: argv is visible to every local user via ps):
#   either  DATABASE_URL=<connection string>   (exported into PGDATABASE for libpq; never passed as an argument)
#   or      the standard PGHOST/PGPORT/PGUSER/PGDATABASE (+ PGPASSWORD or ~/.pgpass)
# Options (environment):
#   SMOKE_PROFILE=production|replay      default production (S20 requires the owner-retain record); replay = throwaway DB
#   SMOKE_PROPOSAL_001_APPLIED=0|1       default 0; 1 = S11 must PASS (proposal 001 live)
#   SMOKE_MODE=main|post001              main = scripts/smoke/smoke_readonly.sql, post001 = post_proposal_001_verify.sql
# Exit 0 only when: the session proved read-only, EVERY expected check row is present exactly once, every status is
# PASS/WARN/INFO, and there is no FAIL. WARN/INFO are reported and never hide a missing or failed row.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${SMOKE_MODE:-main}"
case "$mode" in
  main)    sql="$here/smoke_readonly.sql";          expected="S00 S01 S02 S03 S04 S05 S06 S07 S08 S09 S10 S11 S12 S13 S14 S15 S16 S17 S18 S19 S20 S21 S22 S23" ;;
  post001) sql="$here/post_proposal_001_verify.sql"; expected="P1 P2 P3 P4 P5 P6" ;;
  *) echo "SMOKE: unknown SMOKE_MODE '$mode'" >&2; exit 2 ;;
esac

if [ -n "${DATABASE_URL:-}" ]; then export PGDATABASE="$DATABASE_URL"; fi
if [ -z "${PGDATABASE:-}" ] && [ -z "${PGHOST:-}" ]; then
  echo "SMOKE: set DATABASE_URL (or PGHOST/PGUSER/PGDATABASE). Never pass credentials as arguments." >&2; exit 2
fi

profile="${SMOKE_PROFILE:-production}"; p001="${SMOKE_PROPOSAL_001_APPLIED:-0}"
case "$profile" in production|replay) ;; *) echo "SMOKE: SMOKE_PROFILE must be production or replay" >&2; exit 2 ;; esac
case "$p001" in 0|1) ;; *) echo "SMOKE: SMOKE_PROPOSAL_001_APPLIED must be 0 or 1" >&2; exit 2 ;; esac

# Advisory, not a security boundary: the S00 row below proves the session really was read-only, and the runner refuses otherwise.
export PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=30000 -c smoke.profile=$profile -c smoke.proposal_001_applied=$p001"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"

out="$(psql -X -A -F '|' -t -v ON_ERROR_STOP=1 -f "$sql")"

echo "# $(date -u +%FT%TZ)  mode=$mode profile=$profile commit=$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "$out"
printf '%s\n' "$out" | sha256sum | sed 's/^/# output sha256: /'

# Verdict from parsed rows (awk, no pipe into grep -q: that pattern SIGPIPEs under pipefail on large output and fails open).
verdict="$(awk -F'|' -v expected="$expected" '
  BEGIN { n = split(expected, e, " "); for (i = 1; i <= n; i++) want[e[i]] = 1 }
  NF >= 2 {
    split($1, p, " "); id = p[1]; st = $2
    if (!(id in want)) { extra++; next }
    seen[id]++
    if (st == "FAIL") fail++
    else if (st == "WARN") warn++
    else if (st == "INFO") info++
    else if (st == "PASS") pass++
    else bad++
    if (id == "S00" && st != "PASS") notro = 1
  }
  END {
    for (i = 1; i <= n; i++) { if (seen[e[i]] == 0) missing = missing " " e[i]; if (seen[e[i]] > 1) dup = dup " " e[i] }
    printf "pass=%d fail=%d warn=%d info=%d bad=%d extra=%d notro=%d missing=[%s] dup=[%s]\n", pass, fail, warn, info, bad, extra, notro, missing, dup
  }' <<<"$out")"
echo "# $verdict"

getv() { sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"$verdict"; }
fail="$(getv fail)"; bad="$(getv bad)"; extra="$(getv extra)"; notro="$(getv notro)"; warn="$(getv warn)"
missing="$(sed -n 's/.*missing=\[\([^]]*\)\].*/\1/p' <<<"$verdict")"; dup="$(sed -n 's/.*dup=\[\([^]]*\)\].*/\1/p' <<<"$verdict")"

rc=0
[ "${notro:-0}" = 0 ] || { echo "SMOKE: FAIL (session was not read-only)"; rc=1; }
[ -z "${missing// }" ] || { echo "SMOKE: FAIL (missing check rows:$missing)"; rc=1; }
[ -z "${dup// }" ] || { echo "SMOKE: FAIL (duplicate check rows:$dup)"; rc=1; }
[ "${bad:-0}" = 0 ] || { echo "SMOKE: FAIL (rows with an unknown status)"; rc=1; }
[ "${extra:-0}" = 0 ] || { echo "SMOKE: FAIL (unexpected extra rows: update the runner's expected list deliberately)"; rc=1; }
[ "${fail:-0}" = 0 ] || { echo "SMOKE: FAIL ($fail failing checks)"; rc=1; }
if [ "$rc" = 0 ]; then echo "SMOKE: no FAIL (${warn:-0} WARN, all expected rows present)"; fi
exit "$rc"
