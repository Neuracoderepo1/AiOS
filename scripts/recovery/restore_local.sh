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
object_count="$(psql -X -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname not in ('pg_catalog','information_schema') and c.relkind in ('r','v','m','S','f')")"
[[ "$object_count" == "0" ]] || fail "target database is not empty (user object count=$object_count)"
pg_restore --exit-on-error --single-transaction --no-owner --no-acl --dbname "$PGDATABASE" "$src/database.dump"
printf 'Restore completed into local database %s. Run validate_local_restore.sh next.\n' "$PGDATABASE"
