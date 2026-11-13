#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
for f in "$root"/scripts/recovery/*.sh "$root"/tests/recovery/*.sh; do bash -n "$f"; done
expect_reject() {
  local label="$1"; shift
  local output
  if output="$("$@" 2>&1)"; then
    printf 'FAIL: %s unexpectedly succeeded\n' "$label" >&2
    exit 1
  fi
  printf 'PASS: %s rejected (%s)\n' "$label" "$(printf '%s' "$output" | tail -n 1)"
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/pgpass"
chmod 600 "$tmp/pgpass"
expect_reject "export without explicit approval" env -u AIOS_EXPORT_APPROVAL "$root/scripts/recovery/export_logical.sh" "$tmp/out"
expect_reject "export with invalid approval marker" env AIOS_EXPORT_APPROVAL=maybe "$root/scripts/recovery/export_logical.sh" "$tmp/out"
expect_reject "nonproduction export to remote host" env AIOS_EXPORT_APPROVAL=NONPRODUCTION PGHOST=db.example.invalid PGPORT=5432 PGUSER=postgres PGDATABASE=aios PGPASSFILE="$tmp/pgpass" "$root/scripts/recovery/export_logical.sh" "$tmp/out"
expect_reject "nonproduction export with remote PGHOSTADDR override" env AIOS_EXPORT_APPROVAL=NONPRODUCTION PGHOST=127.0.0.1 PGHOSTADDR=203.0.113.8 PGPORT=5432 PGUSER=postgres PGDATABASE=aios PGPASSFILE="$tmp/pgpass" "$root/scripts/recovery/export_logical.sh" "$tmp/out"
expect_reject "restore against remote host" env PGHOST=db.example.invalid PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" "$root/scripts/recovery/restore_local.sh" "$tmp"
expect_reject "restore with remote PGHOSTADDR override" env PGHOST=127.0.0.1 PGHOSTADDR=203.0.113.8 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" "$root/scripts/recovery/restore_local.sh" "$tmp"
expect_reject "restore with libpq service override" env PGHOST=127.0.0.1 PGSERVICE=remote-service PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" "$root/scripts/recovery/restore_local.sh" "$tmp"
chmod 644 "$tmp/pgpass"
expect_reject "restore with insecure password-file permissions" env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" "$root/scripts/recovery/restore_local.sh" "$tmp"
chmod 600 "$tmp/pgpass"
expect_reject "restore into non-isolated database name" env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres PGPASSFILE="$tmp/pgpass" "$root/scripts/recovery/restore_local.sh" "$tmp"
expect_reject "validation against remote host" env PGHOST=db.example.invalid PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" "$root/scripts/recovery/validate_local_restore.sh" "$tmp"
printf 'RECOVERY SCRIPT SAFETY SELF-TEST: PASS\n'
