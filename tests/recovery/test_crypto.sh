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
AGE_RECIPIENTS_FILE="$TMP/keys/recipient.txt" bash "$ROOT/scripts/recovery/encrypt_artifact.sh" "$TMP/work/synthetic.dump" "$TMP/work/synthetic.dump.age"
bash "$ROOT/scripts/recovery/verify_manifest.sh" "$TMP/work/synthetic.dump.age.sha256"
AGE_IDENTITY_FILE="$TMP/keys/identity.txt" bash "$ROOT/scripts/recovery/decrypt_artifact.sh" "$TMP/work/synthetic.dump.age" "$TMP/work/roundtrip.dump"
cmp "$TMP/work/synthetic.dump" "$TMP/work/roundtrip.dump" || fail "round-trip bytes differ"
pass "authenticated encryption/decryption round trip"
if AGE_IDENTITY_FILE="$TMP/keys/wrong-identity.txt" bash "$ROOT/scripts/recovery/decrypt_artifact.sh" "$TMP/work/synthetic.dump.age" "$TMP/work/wrong.dump" >/dev/null 2>&1; then fail "wrong identity unexpectedly decrypted"; fi
[[ ! -e "$TMP/work/wrong.dump" ]] || fail "wrong-key failure left plaintext output"
pass "wrong-key rejection"
cp "$TMP/work/synthetic.dump.age" "$TMP/work/tampered.age"
printf 'tamper' >> "$TMP/work/tampered.age"
sed 's/synthetic.dump.age/tampered.age/' "$TMP/work/synthetic.dump.age.sha256" > "$TMP/work/tampered.age.sha256"
if bash "$ROOT/scripts/recovery/verify_manifest.sh" "$TMP/work/tampered.age.sha256" >/dev/null 2>&1; then fail "tampered ciphertext passed manifest"; fi
pass "tampered-file detection"
# A valid hash entry must not be allowed to redirect verification to a different file.
sed 's/synthetic.dump.age/unrelated.age/' "$TMP/work/synthetic.dump.age.sha256" > "$TMP/work/substituted.age.sha256"
if bash "$ROOT/scripts/recovery/verify_manifest.sh" "$TMP/work/substituted.age.sha256" >/dev/null 2>&1; then fail "substituted manifest filename accepted"; fi
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

# Exercise exporter dry-run with inert command stubs. No database command may run.
mkdir -p "$TMP/stubs" "$TMP/export-destination"
printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 99\n' "$TMP/command-called" > "$TMP/stubs/pg_dump"
cp "$TMP/stubs/pg_dump" "$TMP/stubs/psql"
chmod 700 "$TMP/stubs/pg_dump" "$TMP/stubs/psql"
printf 'localhost:5432:synthetic:synthetic:not-a-real-password\n' > "$TMP/pgpass"
chmod 600 "$TMP/pgpass"
PATH="$TMP/stubs:$PATH" AIOS_EXPORT_APPROVAL=NONPRODUCTION PGHOST=127.0.0.1 PGPORT=5432 PGUSER=synthetic PGDATABASE=synthetic PGPASSFILE="$TMP/pgpass" \
  bash "$ROOT/scripts/recovery/export_logical.sh" --dry-run "$TMP/export-destination" > "$TMP/dry-run.log"
grep -q 'DRY RUN PASS' "$TMP/dry-run.log" || fail "export dry-run did not report success"
[[ ! -e "$TMP/command-called" ]] || fail "dry-run invoked a database command"
[[ ! -e "$TMP/export-destination/aios-logical-export" ]] || fail "dry-run created an export"
pass "export dry-run performs validation without database access or output"

printf 'All crypto and dry-run self-tests passed. Fixture contained synthetic data only.\n'
