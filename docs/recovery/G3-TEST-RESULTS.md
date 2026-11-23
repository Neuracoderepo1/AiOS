# G3 Recovery Test Results

**Evidence date:** 2026-11-23  
**Repository base:** `fe1fcbea1e9aba02689cb0bb48c0a1180e508504` (PR #42 head)  
**Latest exact-head test execution:** PENDING CI for current feature head. Earlier crypto suite passed on commit `bcf657e55e1234da3c753ee83b52e9b6ab035bae` (run #1, 23 November 2026); that run predates the exporter dry-run enhancement now on the branch.

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
| age round trip | PASS on prior tested commit; rerun pending for current head | Synthetic fixture only |
| wrong-key rejection | PASS on prior tested commit; rerun pending for current head | Synthetic fixture only |
| tamper detection | PASS on prior tested commit; rerun pending for current head | Synthetic fixture only |
| SHA-256 manifest verification | PASS on prior tested commit; rerun pending for current head | Synthetic fixture only |
| missing-file handling | PASS on prior tested commit; rerun pending for current head | Synthetic fixture only |
| incomplete-export handling | PASS on prior tested commit; rerun pending for current head | Synthetic fixture only |
| insufficient-storage handling | PENDING CI | Guard behavior only; no real production disk tested |
| credential-redaction checks | PENDING CI | Synthetic sentinel values only |
| exporter dry-run / no database side effects | PENDING CI for current head | New inert-command-stub test; not covered by prior run #1 |
| isolated PostgreSQL restore | Existing CI suite; exact branch result pending | Disposable synthetic database only |
| recovery evidence completeness | PENDING CI | Evidence manifest checklist |

## Timestamp and evidence policy

Prior crypto run: https://github.com/Neuracoderepo1/AiOS/actions/runs/45181482996, commit `bcf657e55e1234da3c753ee83b52e9b6ab035bae`, conclusion SUCCESS. Full AiOS CI #415 was still in progress when this evidence note was prepared. Record new exact-head workflow URLs and results after the dry-run enhancement is validated. Do not fill PASS based on expected behavior or local code inspection. If CI does not run or is cancelled, retain PENDING. If any test fails, record FAIL with a sanitized failure summary.

Production restore status remains NOT STARTED regardless of synthetic test results.
