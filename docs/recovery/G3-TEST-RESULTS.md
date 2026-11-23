# G3 Recovery Test Results

**Evidence date:** 2026-11-23  
**Repository base:** `fe1fcbea1e9aba02689cb0bb48c0a1180e508504` (PR #42 head)  
**Test execution status:** PENDING CI on this feature branch.

## Scope boundary

No production export, production credentials, production database writes, production restore, Google Drive upload, or owner-device inspection was performed. Synthetic test data must never be described as production recovery evidence.

## Automated test commands

The new crypto self-test command is:

```sh
bash tests/recovery/test_crypto.sh
```

It requires `age` and standard POSIX shell utilities. It creates only a temporary synthetic payload and temporary test identity. It covers:
- authenticated encryption/decryption round trip;
- wrong-identity rejection;
- ciphertext tamper detection;
- SHA-256 manifest success and mismatch;
- missing input/manifest rejection;
- incomplete export and credential-redaction smoke checks;
- refusal to overwrite existing output paths.

Existing recovery safety tests:

```sh
bash tests/recovery/test_scripts.sh
```

Disposable PostgreSQL tests (requires an explicitly disposable local Supabase/PostgreSQL fixture):

```sh
AIOS_TEST_DB_URL='<loopback-only disposable test database>' bash tests/recovery/postgres_roundtrip.sh
AIOS_TEST_DB_URL='<loopback-only disposable test database>' bash tests/recovery/preflight_matrix.sh
```

Do not run these PostgreSQL commands with a hosted/production URL. The test scripts must validate loopback and disposable database identity.

## Results

| Test group | Result | Evidence |
|---|---|---|
| age round trip | PENDING CI | Synthetic fixture only |
| wrong-key rejection | PENDING CI | Synthetic fixture only |
| tamper detection | PENDING CI | Synthetic fixture only |
| SHA-256 manifest verification | PENDING CI | Synthetic fixture only |
| missing-file handling | PENDING CI | Synthetic fixture only |
| incomplete-export handling | PENDING CI | Synthetic fixture only |
| insufficient-storage handling | PENDING CI | Guard behavior only; no real production disk tested |
| credential-redaction checks | PENDING CI | Synthetic sentinel values only |
| dry-run / no automatic export | PENDING CI | Static and shell self-tests |
| isolated PostgreSQL restore | Existing CI suite; exact branch result pending | Disposable synthetic database only |
| recovery evidence completeness | PENDING CI | Evidence manifest checklist |

## Timestamp and evidence policy

Record UTC timestamps, exact workflow run URLs, commit SHA, command exit codes and artifact digests after the branch CI completes. Do not fill PASS based on expected behavior or local code inspection. If CI does not run or is cancelled, retain PENDING. If any test fails, record FAIL with a sanitized failure summary.

Production restore status remains NOT STARTED regardless of synthetic test results.
