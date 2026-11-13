#!/usr/bin/env bash
# Restore a logical archive into a pre-created, empty local PostgreSQL database only.
set -Eeuo pipefail
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for name in PGHOST PGPORT PGUSER PGDATABASE PGPASSFILE; do
  [[ -n "${!name:-}" ]] || fail "missing required libpq variable: $name"
done
case "$PGHOST" in localhost|127.0.0.1|::1) ;; *) fail "restore target must be loopback; refusing remote host" ;; esac
[[ -z "${PGHOSTADDR:-}" || "$PGHOSTADDR" == 127.0.0.1 || "$PGHOSTADDR" == ::1 ]] || fail "PGHOSTADDR must be loopback"
[[ -z "${PGSERVICE:-}" && -z "${PGSERVICEFILE:-}" ]] || fail "PGSERVICE/PGSERVICEFILE are not allowed for isolated restore"
[[ -f "$PGPASSFILE" ]] || fail "PGPASSFILE must name an existing password file"
python3 - "$PGPASSFILE" <<'PY'
import os, stat, sys
if stat.S_IMODE(os.stat(sys.argv[1]).st_mode) & 0o077:
    raise SystemExit("PGPASSFILE permissions must be 0600 or stricter")
PY
[[ "$PGDATABASE" == aios_restore_* ]] || fail "target database name must start with aios_restore_"
command -v pg_restore >/dev/null || fail "pg_restore is required"
command -v psql >/dev/null || fail "psql is required"
command -v python3 >/dev/null || fail "python3 is required"
[[ $# -eq 1 ]] || fail "usage: $0 <export-directory>"
src="$(cd "$1" && pwd -P)"
[[ -s "$src/database.dump" && -s "$src/SHA256SUMS" ]] || fail "archive or checksum manifest missing"
(
 cd "$src"
 if command -v sha256sum >/dev/null; then sha256sum -c SHA256SUMS
 else shasum -a 256 -c SHA256SUMS
 fi
)
pg_restore --list "$src/database.dump" >/dev/null || fail "archive validation failed"
exists="$(psql -X -v ON_ERROR_STOP=1 -Atc "select 1 from pg_database where datname = current_database()")"
[[ "$exists" == "1" ]] || fail "target database is not available"

# Fail closed on any pre-existing user object in the ENUMERATED classes (see
# preflight_target_empty.sql for the exact list and the explicit exclusions). The
# preflight is read-only and nothing in the target is ever dropped, truncated or
# altered. Classes that are not enumerated (extensions themselves, event triggers,
# publications, foreign data wrappers/servers, casts, languages, ...) are not
# predicted here: a collision in one of them is stopped by the single-transaction,
# exit-on-error pg_restore below, which leaves the target exactly as it was.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
preflight_sql="$script_dir/preflight_target_empty.sql"
[[ -s "$preflight_sql" ]] || fail "restore preflight query is missing: $preflight_sql"
conflicts="$(PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c default_transaction_read_only=on" \
  psql -X -q -v ON_ERROR_STOP=1 -At -f "$preflight_sql")" || fail "restore preflight query failed; refusing to restore"
object_count="$(printf '%s\n' "$conflicts" | grep -c . || true)"
if [[ "$object_count" != "0" ]]; then
  listing="$(printf '%s\n' "$conflicts" | head -n 20 | paste -sd ';' - | sed 's/;/; /g')"
  fail "target database is not empty (pre-existing user objects=$object_count; first up to 20: $listing)"
fi
pg_restore --exit-on-error --single-transaction --no-owner --no-acl --dbname "$PGDATABASE" "$src/database.dump"
printf 'Restore completed into local database %s. Run validate_local_restore.sh next.\n' "$PGDATABASE"
