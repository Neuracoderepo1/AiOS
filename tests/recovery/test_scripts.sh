#!/usr/bin/env bash
# Fail-closed guard self-tests for the recovery scripts. No database is contacted.
#
# Every case must be rejected BY THE INTENDED GUARD: the captured output has to contain
# the guard's own message. Scripts are run with `bash <script>` so the result never
# depends on the executable bit (a bare "Permission denied" would otherwise look like a
# successful rejection and make every case pass without running any guard).
set -Eeuo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
for f in "$root"/scripts/recovery/*.sh "$root"/tests/recovery/*.sh; do bash -n "$f"; done
[[ -s "$root/scripts/recovery/preflight_target_empty.sql" ]] || { echo "FAIL: preflight SQL missing" >&2; exit 1; }

expect_reject() {
  local label="$1" expected="$2"; shift 2
  local output
  if output="$("$@" 2>&1)"; then
    printf 'FAIL: %s unexpectedly succeeded\n' "$label" >&2
    exit 1
  fi
  if [[ "$output" == *"Permission denied"* || "$output" == *"command not found"* || "$output" == *"No such file"* ]]; then
    printf 'FAIL: %s was rejected because the script could not run, not by its guard: %s\n' "$label" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL: %s was rejected by the wrong guard.\n  expected message containing: %s\n  actual output: %s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
  printf 'PASS: %s rejected by intended guard (%s)\n' "$label" "$expected"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/pgpass"
chmod 600 "$tmp/pgpass"
export_sh="$root/scripts/recovery/export_logical.sh"
restore_sh="$root/scripts/recovery/restore_local.sh"
validate_sh="$root/scripts/recovery/validate_local_restore.sh"

expect_reject "export without explicit approval" "Set AIOS_EXPORT_APPROVAL" \
  env -u AIOS_EXPORT_APPROVAL bash "$export_sh" "$tmp/out"
expect_reject "export with invalid approval marker" "explicit NONPRODUCTION or owner-approved export marker required" \
  env AIOS_EXPORT_APPROVAL=maybe PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=aios PGPASSFILE="$tmp/pgpass" bash "$export_sh" "$tmp/out"
expect_reject "nonproduction export to remote host" "NONPRODUCTION marker is restricted to loopback" \
  env AIOS_EXPORT_APPROVAL=NONPRODUCTION PGHOST=db.example.invalid PGPORT=5432 PGUSER=postgres PGDATABASE=aios PGPASSFILE="$tmp/pgpass" bash "$export_sh" "$tmp/out"
expect_reject "nonproduction export with remote PGHOSTADDR override" "NONPRODUCTION export cannot use a remote PGHOSTADDR" \
  env AIOS_EXPORT_APPROVAL=NONPRODUCTION PGHOST=127.0.0.1 PGHOSTADDR=203.0.113.8 PGPORT=5432 PGUSER=postgres PGDATABASE=aios PGPASSFILE="$tmp/pgpass" bash "$export_sh" "$tmp/out"
expect_reject "restore against remote host" "restore target must be loopback" \
  env PGHOST=db.example.invalid PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" bash "$restore_sh" "$tmp"
expect_reject "restore with remote PGHOSTADDR override" "PGHOSTADDR must be loopback" \
  env PGHOST=127.0.0.1 PGHOSTADDR=203.0.113.8 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" bash "$restore_sh" "$tmp"
expect_reject "restore with libpq service override" "PGSERVICE/PGSERVICEFILE are not allowed" \
  env PGHOST=127.0.0.1 PGSERVICE=remote-service PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" bash "$restore_sh" "$tmp"
chmod 644 "$tmp/pgpass"
expect_reject "restore with insecure password-file permissions" "PGPASSFILE permissions must be 0600 or stricter" \
  env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" bash "$restore_sh" "$tmp"
chmod 600 "$tmp/pgpass"
expect_reject "restore into non-isolated database name" "target database name must start with aios_restore_" \
  env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres PGPASSFILE="$tmp/pgpass" bash "$restore_sh" "$tmp"
expect_reject "validation against remote host" "validation target must be loopback" \
  env PGHOST=db.example.invalid PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" bash "$validate_sh" "$tmp"

# Static contract: the restore path must stay non-destructive and transactional.
strip_comments() { sed -E 's/^[[:space:]]*(#|--).*$//' "$1"; }
restore_code="$(strip_comments "$restore_sh")"
preflight_code="$(strip_comments "$root/scripts/recovery/preflight_target_empty.sql")"
for needle in --single-transaction --exit-on-error; do
  [[ "$restore_code" == *"$needle"* ]] || { printf 'FAIL: restore_local.sh no longer uses %s\n' "$needle" >&2; exit 1; }
done
if printf '%s\n%s\n' "$restore_code" "$preflight_code" | grep -Eiq '(^|[^A-Za-z_])(drop|truncate|delete[[:space:]]+from|alter|create|insert|update)([^A-Za-z_]|$)|--clean|--create|dropdb'; then
  printf 'FAIL: restore preflight/restore code contains a destructive or mutating statement\n' >&2
  exit 1
fi
printf 'PASS: restore path is single-transaction/exit-on-error and contains no drop/clean/create/alter/mutation statements\n'
printf 'RECOVERY SCRIPT SAFETY SELF-TEST: PASS\n'
