#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
command -v age >/dev/null 2>&1 || fail "age missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
mkdir -p "$TMP/keys" "$TMP/work"
age-keygen -o "$TMP/keys/identity.txt" 2>"$TMP/keygen.log"
age-keygen -y "$TMP/keys/identity.txt" > "$TMP/keys/recipient.txt"
age-keygen -o "$TMP/keys/wrong-identity.txt" 2>"$TMP/wrong-keygen.log"
age-keygen -y "$TMP/keys/wrong-identity.txt" > "$TMP/keys/wrong-recipient.txt"
chmod 600 "$TMP/keys/identity.txt" "$TMP/keys/wrong-identity.txt" "$TMP/keys/recipient.txt" "$TMP/keys/wrong-recipient.txt"
printf 'synthetic recovery fixture; no production data\n' > "$TMP/work/synthetic.dump"

# All recovery material and outputs must be absolute paths outside the checkout.
if (cd "$TMP" && AGE_RECIPIENTS_FILE="$TMP/keys/recipient.txt" bash "$ROOT/scripts/recovery/encrypt_artifact.sh" work/synthetic.dump "$TMP/work/relative.age") >/dev/null 2>&1; then fail "relative input path accepted"; fi
if AGE_RECIPIENTS_FILE="$TMP/keys/recipient.txt" bash "$ROOT/scripts/recovery/encrypt_artifact.sh" "$ROOT/scripts/recovery/verify_manifest.sh" "$TMP/work/repo-input.age" >/dev/null 2>&1; then fail "repository-contained input accepted"; fi
if AGE_RECIPIENTS_FILE="$TMP/keys/recipient.txt" bash "$ROOT/scripts/recovery/encrypt_artifact.sh" "$TMP/work/synthetic.dump" "$ROOT/.aios-test-output.age" >/dev/null 2>&1; then fail "repository-contained ciphertext output accepted"; fi
if AGE_RECIPIENTS_FILE="$ROOT/scripts/recovery/encrypt_artifact.sh" bash "$ROOT/scripts/recovery/encrypt_artifact.sh" "$TMP/work/synthetic.dump" "$TMP/work/repo-key.age" >/dev/null 2>&1; then fail "repository-contained recipient file accepted"; fi
ln -s "$ROOT" "$TMP/repo-link"
if AGE_RECIPIENTS_FILE="$TMP/keys/recipient.txt" bash "$ROOT/scripts/recovery/encrypt_artifact.sh" "$TMP/work/synthetic.dump" "$TMP/repo-link/.aios-test-output.age" >/dev/null 2>&1; then fail "symlinked repository output parent accepted"; fi
pass "absolute paths and canonical repository/symlink containment"
if bash "$ROOT/scripts/recovery/verify_manifest.sh" "$ROOT/scripts/recovery/verify_manifest.sh" >/dev/null 2>&1; then fail "repository-contained checksum input accepted"; fi
pass "standalone checksum verifier enforces repository path containment"

AGE_RECIPIENTS_FILE="$TMP/keys/recipient.txt" bash "$ROOT/scripts/recovery/encrypt_artifact.sh" "$TMP/work/synthetic.dump" "$TMP/work/synthetic.dump.age"
bash "$ROOT/scripts/recovery/verify_manifest.sh" "$TMP/work/synthetic.dump.age.sha256"
AGE_IDENTITY_FILE="$TMP/keys/identity.txt" bash "$ROOT/scripts/recovery/decrypt_artifact.sh" "$TMP/work/synthetic.dump.age" "$TMP/work/roundtrip.dump"
cmp "$TMP/work/synthetic.dump" "$TMP/work/roundtrip.dump" || fail "round-trip bytes differ"
pass "authenticated encryption/decryption round trip"
if AGE_IDENTITY_FILE="$TMP/keys/wrong-identity.txt" bash "$ROOT/scripts/recovery/decrypt_artifact.sh" "$TMP/work/synthetic.dump.age" "$TMP/work/wrong.dump" >/dev/null 2>&1; then fail "wrong identity unexpectedly decrypted"; fi
[[ ! -e "$TMP/work/wrong.dump" ]] || fail "wrong-key failure left plaintext output"
pass "wrong-key rejection"
if AGE_IDENTITY_FILE="$ROOT/scripts/recovery/decrypt_artifact.sh" bash "$ROOT/scripts/recovery/decrypt_artifact.sh" "$TMP/work/synthetic.dump.age" "$TMP/work/repo-identity.dump" >/dev/null 2>&1; then fail "repository-contained identity accepted"; fi
if AGE_IDENTITY_FILE="$TMP/keys/identity.txt" bash "$ROOT/scripts/recovery/decrypt_artifact.sh" "$TMP/work/synthetic.dump.age" "$ROOT/.aios-plaintext-test.dump" >/dev/null 2>&1; then fail "repository-contained plaintext output accepted"; fi
if AGE_IDENTITY_FILE="$TMP/keys/identity.txt" bash "$ROOT/scripts/recovery/decrypt_artifact.sh" "$TMP/work/synthetic.dump.age" "$TMP/repo-link/.aios-plaintext-test.dump" >/dev/null 2>&1; then fail "symlinked repository plaintext parent accepted"; fi
if (cd "$TMP" && AGE_IDENTITY_FILE="$TMP/keys/identity.txt" bash "$ROOT/scripts/recovery/decrypt_artifact.sh" work/synthetic.dump.age "$TMP/work/relative-plaintext.dump") >/dev/null 2>&1; then fail "relative ciphertext path accepted"; fi
pass "identity, ciphertext and plaintext path containment"

cp "$TMP/work/synthetic.dump.age" "$TMP/work/tampered.age"
printf 'tamper' >> "$TMP/work/tampered.age"
sed 's/synthetic.dump.age/tampered.age/' "$TMP/work/synthetic.dump.age.sha256" > "$TMP/work/tampered.age.sha256"
if bash "$ROOT/scripts/recovery/verify_manifest.sh" "$TMP/work/tampered.age.sha256" >/dev/null 2>&1; then fail "tampered ciphertext passed manifest"; fi
pass "tampered-file detection"
sed 's/synthetic.dump.age/unrelated.age/' "$TMP/work/synthetic.dump.age.sha256" > "$TMP/work/synthetic.dump.age.sha256.tmp"
mv "$TMP/work/synthetic.dump.age.sha256.tmp" "$TMP/work/synthetic.dump.age.sha256"
if bash "$ROOT/scripts/recovery/verify_manifest.sh" "$TMP/work/synthetic.dump.age.sha256" > "$TMP/work/substitution.log" 2>&1; then fail "substituted manifest filename accepted"; fi
grep -q "manifest filename does not match" "$TMP/work/substitution.log" || fail "manifest substitution test did not reach the filename-binding guard"
# Restore the original valid manifest for subsequent tests.
printf '%s  synthetic.dump.age\n' "$(sha256sum "$TMP/work/synthetic.dump.age" | awk '{print $1}')" > "$TMP/work/synthetic.dump.age.sha256"
pass "manifest is bound to the exact ciphertext filename"
if bash "$ROOT/scripts/recovery/verify_manifest.sh" "$TMP/work/missing.sha256" >/dev/null 2>&1; then fail "missing manifest accepted"; fi
if AGE_RECIPIENTS_FILE="$TMP/keys/recipient.txt" bash "$ROOT/scripts/recovery/encrypt_artifact.sh" "$TMP/work/missing.dump" "$TMP/work/missing.age" >/dev/null 2>&1; then fail "missing input accepted"; fi
pass "missing-file handling"
if AGE_RECIPIENTS_FILE="$TMP/keys/recipient.txt" AIOS_TEST_MIN_FREE_KB=1 bash "$ROOT/scripts/recovery/encrypt_artifact.sh" "$TMP/work/synthetic.dump" "$TMP/work/insufficient.age" >/dev/null 2>&1; then fail "insufficient-storage simulation accepted"; fi
[[ ! -e "$TMP/work/insufficient.age" ]] || fail "insufficient-space guard left output"
pass "insufficient-storage fail-closed simulation"
printf 'different\n' > "$TMP/work/modified.dump"
if AGE_RECIPIENTS_FILE="$TMP/keys/recipient.txt" bash "$ROOT/scripts/recovery/encrypt_artifact.sh" "$TMP/work/modified.dump" "$TMP/work/synthetic.dump.age" >/dev/null 2>&1; then fail "existing output overwritten"; fi
pass "overwrite refusal"
if grep -Eiq 'password=|postgres(ql)?://[^[:space:]]+|AGE-SECRET-KEY-' "$TMP/keygen.log" "$TMP/wrong-keygen.log"; then fail "key-generation output leaked a credential/key"; fi
pass "key material absent from captured tool logs"
grep -q 'NONPRODUCTION' "$ROOT/docs/operations/LOGICAL-EXPORT-RESTORE.md" || fail "export guard documentation missing"
pass "production export not invoked by crypto tests"

# Exercise exporter dry-run and remote TLS policy with inert database-command stubs.
mkdir -p "$TMP/stubs" "$TMP/export-destination"
printf '#!/bin/sh\n: > "%s"\nexit 99\n' "$TMP/command-called" > "$TMP/stubs/pg_dump"
cp "$TMP/stubs/pg_dump" "$TMP/stubs/psql"
chmod 700 "$TMP/stubs/pg_dump" "$TMP/stubs/psql"
printf 'localhost:5432:synthetic:synthetic:not-a-real-password\n' > "$TMP/pgpass"
chmod 600 "$TMP/pgpass"
env PATH="$TMP/stubs:$PATH" AIOS_EXPORT_APPROVAL=NONPRODUCTION PGHOST=127.0.0.1 PGPORT=5432 PGUSER=synthetic PGDATABASE=synthetic PGPASSFILE="$TMP/pgpass" bash "$ROOT/scripts/recovery/export_logical.sh" --dry-run "$TMP/export-destination" > "$TMP/dry-run.log"
grep -q 'DRY RUN PASS' "$TMP/dry-run.log" || fail "export dry-run did not report success"
[[ ! -e "$TMP/command-called" ]] || fail "dry-run invoked a database command"
[[ ! -e "$TMP/export-destination/aios-logical-export" ]] || fail "dry-run created an export"
pass "export dry-run performs validation without database access or output"

printf 'fake CA fixture\n' > "$TMP/ca.pem"
if PATH="$TMP/stubs:$PATH" AIOS_EXPORT_APPROVAL=OWNER_APPROVED_PRODUCTION:test-approval PGHOST=db.example.invalid PGPORT=5432 PGUSER=synthetic PGDATABASE=synthetic PGPASSFILE="$TMP/pgpass" PGSSLMODE=require PGSSLROOTCERT="$TMP/ca.pem" bash "$ROOT/scripts/recovery/export_logical.sh" --dry-run "$TMP/export-destination" >/dev/null 2>&1; then fail "remote export accepted non-verify-full TLS"; fi
if PATH="$TMP/stubs:$PATH" AIOS_EXPORT_APPROVAL=OWNER_APPROVED_PRODUCTION:test-approval PGHOST=db.example.invalid PGPORT=5432 PGUSER=synthetic PGDATABASE=synthetic PGPASSFILE="$TMP/pgpass" PGSSLMODE=verify-full PGSSLROOTCERT="$TMP/ca.pem" PGSERVICE=unreviewed bash "$ROOT/scripts/recovery/export_logical.sh" --dry-run "$TMP/export-destination" >/dev/null 2>&1; then fail "remote export accepted PGSERVICE override"; fi
if PATH="$TMP/stubs:$PATH" AIOS_EXPORT_APPROVAL=OWNER_APPROVED_PRODUCTION:test-approval PGHOST=db.example.invalid PGPORT=5432 PGUSER=synthetic PGDATABASE=synthetic PGPASSFILE="$TMP/pgpass" PGSSLMODE=verify-full PGSSLROOTCERT="$TMP/ca.pem" PGHOSTADDR=192.0.2.10 bash "$ROOT/scripts/recovery/export_logical.sh" --dry-run "$TMP/export-destination" >/dev/null 2>&1; then fail "remote export accepted PGHOSTADDR override"; fi
[[ ! -e "$TMP/command-called" ]] || fail "remote TLS policy tests invoked a database command"
pass "remote export requires verify-full TLS and rejects libpq connection overrides"

printf 'All crypto, path-containment and exporter safety self-tests passed. Fixture contained synthetic data only.\n'
