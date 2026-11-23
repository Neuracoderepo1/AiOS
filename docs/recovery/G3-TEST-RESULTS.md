# G3 Recovery Test Results

**Evidence date:** 2026-11-23  
**Repository base:** `fe1fcbea1e9aba02689cb0bb48c0a1180e508504` (PR #42 head)  
**Latest exact-head validation:** Recovery crypto workflow #5 PASS and full AiOS CI #419 PASS on feature head `9997b328e32a9ac542f914dbdc6d92bf3e34949d`.

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
- incomplete-export and credential-redaction smoke checks;
- refusal to overwrite existing output paths.

The exporter dry-run tests use inert command stubs and verify that dry-run does not invoke database commands or create output artifacts.

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

| Test group | Result | Evidence / limitation |
|---|---|---|
| Recovery crypto safety workflow | PASS | Workflow #5, run 45181979802, exact feature head `9997b328e32a9ac542f914dbdc6d92bf3e34949d` |
| age round trip, wrong-key rejection, tamper detection, SHA-256 verification, missing-file handling, overwrite refusal | PASS | Included in exact-head Recovery crypto workflow #5; synthetic fixtures only |
| Exporter dry-run / no database side effects | PASS | Included in exact-head full AiOS CI #419 recovery script test coverage; inert command stubs only |
| Credential-redaction and incomplete-export guards | PASS | Included in exact-head full AiOS CI #419; synthetic sentinel values and guard tests only |
| Full AiOS CI | PASS | Run 45181979825; all four jobs passed: `functions-behavioral`, `evidence-integrity`, `functions-typecheck`, `migrations-and-sql-tests` |
| Isolated PostgreSQL CI validation | PASS | Full AiOS CI #419 migration/SQL test job passed, including disposable test database stages; not a production-equivalent restore |
| Google Drive upload/download round trip | NOT RUN | No authenticated Drive integration available to this agent |
| Human Director local FileVault, free space, PostgreSQL inventory | NOT VERIFIED | Owner device is not accessible from this execution environment |
| Production export and isolated production-artifact restore | NOT STARTED | Explicitly unauthorized while G3 prerequisites remain unresolved |
| Agent 003 independent review | PENDING | Exact-head review requested; no submitted review disposition recorded at this checkpoint |

## Workflow evidence

- Full AiOS CI #419: https://github.com/Neuracoderepo1/AiOS/actions/runs/45181979825
- Recovery crypto safety workflow #5: https://github.com/Neuracoderepo1/AiOS/actions/runs/45181979802

## Timestamp and evidence policy

These workflow conclusions apply to the exact feature head stated above. If a subsequent commit changes the feature head, rerun the relevant workflows and update this record. Cancelled superseded runs are not counted as passes or failures. Do not fill PASS based on expected behavior or code inspection alone.

Production restore status remains NOT STARTED regardless of synthetic CI results. G3 production export remains BLOCKED until owner-side storage/custody/target evidence and Agent 003's independent review are complete, followed by separate exact-operation authorization from the Human Director.
