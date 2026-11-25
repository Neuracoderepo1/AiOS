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

# Destructive PostgreSQL fixtures require an explicit per-run acknowledgement.
expect_reject "roundtrip without destructive fixture opt-in" "destructive fixture opt-in required" \\
  env -u AIOS_TEST_DB_DESTRUCTIVE_ACK AIOS_TEST_DB_URL=postgresql://user:pass@127.0.0.1:5432/postgres bash "$root/tests/recovery/postgres_roundtrip.sh"
expect_reject "preflight matrix without destructive fixture opt-in" "destructive fixture opt-in required" \\
  env AIOS_TEST_DB_URL=postgresql://user:pass@127.0.0.1:5432/postgres -u AIOS_TEST_DB_DESTRUCTIVE_ACK bash "$root/tests/recovery/preflight_matrix.sh"

# Standalone validation must reject a changed source inventory before connecting to PostgreSQL.
manifest_fixture="$tmp/manifest-fixture"
mkdir -m 700 "$manifest_fixture"
for name in database.dump schema.sql extensions.tsv source.txt archive.list manifest.txt; do printf 'fixture-%s\\n' "$name" > "$manifest_fixture/$name"; done
(cd "$manifest_fixture" && sha256sum database.dump schema.sql extensions.tsv source.txt archive.list manifest.txt > SHA256SUMS)
printf 'tampered-extension-inventory\\n' >> "$manifest_fixture/extensions.tsv"
expect_reject "validation rejects post-restore export-manifest tampering before database access" "SHA-256 mismatch for extensions.tsv" \\
  env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" bash "$validate_sh" "$manifest_fixture"

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
ln -s "$tmp/pgpass" "$tmp/pgpass-link"
expect_reject "restore with symlinked password file" "recovery input/key paths cannot be symlinks" \
  env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass-link" bash "$restore_sh" "$tmp"
expect_reject "validation with symlinked password file" "recovery input/key paths cannot be symlinks" \
  env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass-link" bash "$validate_sh" "$tmp"
expect_reject "restore with relative password path" "recovery paths must be absolute" \
  env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE=relative-pgpass bash "$restore_sh" "$tmp"
expect_reject "validation with repository-contained password path" "must remain outside the repository" \
  env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$root/scripts/recovery/restore_local.sh" bash "$validate_sh" "$tmp"
expect_reject "restore from repository-contained export directory" "must remain outside the repository" \
  env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" bash "$restore_sh" "$root/scripts/recovery"
expect_reject "validation from repository-contained export directory" "must remain outside the repository" \
  env PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=aios_restore_test PGPASSFILE="$tmp/pgpass" bash "$validate_sh" "$root/scripts/recovery"
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
