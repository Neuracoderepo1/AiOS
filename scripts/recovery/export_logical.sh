#!/usr/bin/env bash
# Create a private, checksummed PostgreSQL logical export.
# Credentials are read only from libpq environment/PGPASSFILE, never command-line arguments.
set -Eeuo pipefail
umask 077

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
: "${AIOS_EXPORT_APPROVAL:?Set AIOS_EXPORT_APPROVAL to NONPRODUCTION or OWNER_APPROVED_PRODUCTION:<approval-id>}"
for name in PGHOST PGPORT PGUSER PGDATABASE PGPASSFILE; do
  [[ -n "${!name:-}" ]] || fail "missing required libpq variable: $name"
done
case "$AIOS_EXPORT_APPROVAL" in
  NONPRODUCTION)
    case "$PGHOST" in localhost|127.0.0.1|::1) ;; *) fail "NONPRODUCTION marker is restricted to loopback; remote export requires an explicit owner approval ID" ;; esac
    [[ -z "${PGHOSTADDR:-}" || "$PGHOSTADDR" == 127.0.0.1 || "$PGHOSTADDR" == ::1 ]] || fail "NONPRODUCTION export cannot use a remote PGHOSTADDR"
    [[ -z "${PGSERVICE:-}" && -z "${PGSERVICEFILE:-}" ]] || fail "PGSERVICE/PGSERVICEFILE are not allowed for NONPRODUCTION export"
    ;;
  OWNER_APPROVED_NONPRODUCTION:*|OWNER_APPROVED_PRODUCTION:*)
    approval_id="${AIOS_EXPORT_APPROVAL#*:}"
    [[ -n "$approval_id" && "$approval_id" != *[!A-Za-z0-9._:-]* ]] || fail "invalid owner approval identifier"
    ;;
  *) fail "export denied: explicit NONPRODUCTION or owner-approved export marker required" ;;
esac
[[ -f "$PGPASSFILE" ]] || fail "PGPASSFILE must name an existing password file"
python3 - "$PGPASSFILE" <<'PY'
import os, stat, sys
mode = stat.S_IMODE(os.stat(sys.argv[1]).st_mode)
if mode & 0o077:
    raise SystemExit("PGPASSFILE permissions must be 0600 or stricter")
PY
command -v pg_dump >/dev/null || fail "pg_dump is required"
command -v psql >/dev/null || fail "psql is required"
command -v python3 >/dev/null || fail "python3 is required"
[[ $# -eq 1 ]] || fail "usage: $0 <absolute-output-directory>"
out="$1"
[[ "$out" = /* ]] || fail "output directory must be an absolute path"
mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
case "$out/" in "$repo_root/"*) fail "refusing to write database exports inside the repository" ;; esac
[[ ! -e "$out/aios-logical-export" ]] || fail "output already exists; choose a new empty destination"
tmp="$(mktemp -d "$out/.aios-export.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

pg_dump --format=custom --no-owner --no-acl --file "$tmp/database.dump"
pg_dump --schema-only --no-owner --no-acl --file "$tmp/schema.sql"
psql -X -v ON_ERROR_STOP=1 -Atc "select extname || E'\t' || extversion from pg_extension order by extname" > "$tmp/extensions.tsv"
psql -X -v ON_ERROR_STOP=1 -Atc "select current_setting('server_version'), current_database()" > "$tmp/source.txt"
[[ -s "$tmp/database.dump" && -s "$tmp/schema.sql" && -s "$tmp/source.txt" ]] || fail "export produced an empty required artifact"
pg_restore --list "$tmp/database.dump" > "$tmp/archive.list"
[[ -s "$tmp/archive.list" ]] || fail "custom archive has no readable entries"
{
  printf 'format=pg_dump-custom\n'
  printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'source_server_and_database=%s\n' "$(tr '\n' ' ' < "$tmp/source.txt")"
  printf 'approval_class=%s\n' "${AIOS_EXPORT_APPROVAL%%:*}"
  printf 'pg_dump_version=%s\n' "$(pg_dump --version)"
} > "$tmp/manifest.txt"
(
  cd "$tmp"
  if command -v sha256sum >/dev/null; then sha256sum database.dump schema.sql extensions.tsv source.txt archive.list manifest.txt > SHA256SUMS
  else shasum -a 256 database.dump schema.sql extensions.tsv source.txt archive.list manifest.txt > SHA256SUMS
  fi
)
chmod -R go-rwx "$tmp"
mv "$tmp" "$out/aios-logical-export"
trap - EXIT
printf 'Export created: %s/aios-logical-export\n' "$out"
printf 'Verify with: (cd %q && sha256sum -c SHA256SUMS)\n' "$out/aios-logical-export"
