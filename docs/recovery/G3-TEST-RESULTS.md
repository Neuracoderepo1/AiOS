# G3 Recovery Test Results

**Evidence date:** 2026-11-23  
**PR:** #43  
**Exact validated feature head:** `48e1c23c946f96e75d9b60005b140cdbf2102fc9`

## Scope boundary

No production export, production credentials, production database writes, production restore, Google Drive upload, or owner-device inspection was performed. Synthetic test data must never be described as production recovery evidence.

## Automated test commands

The crypto self-test command is:

```sh
bash tests/recovery/test_crypto.sh
```

It requires `age` and standard POSIX shell utilities. It creates only a temporary synthetic payload and temporary test identity. Coverage includes:
- authenticated encryption/decryption round trip;
- wrong-identity rejection;
- ciphertext tamper detection;
- SHA-256 manifest success and mismatch;
- missing input/manifest rejection;
- insufficient-storage fail-closed simulation;
- refusal to overwrite existing output paths;
- key-material absence from captured tool logs;
- exporter dry-run proof that no database command runs and no export output is created.

The exporter dry-run tests use inert command stubs. They do not connect to PostgreSQL.

Existing recovery safety tests:

```sh
bash tests/recovery/test_scripts.sh
```

Disposable PostgreSQL tests (requires an explicitly disposable local Supabase/PostgreSQL fixture):

```sh
AIOS_TEST_DB_URL='<loopback-only disposable test database>' bash tests/recovery/postgres_roundtrip.sh
AIOS_TEST_DB_URL='<loopback-only disposable test database>' bash tests/recovery/preflight_matrix.sh
```

Never run these PostgreSQL commands with a hosted/production URL. The test scripts must validate loopback and disposable database identity.

## Exact-head workflow results

| Workflow | Run | Result | Scope |
|---|---:|---|---|
| Full AiOS CI | #421 / 45184608345 | PASS | All four jobs: functions typecheck, evidence integrity, behavioral suite, migrations and SQL tests |
| Recovery crypto safety | #7 / 45184608305 | PASS | Synthetic encryption/decryption, tamper, key, manifest and exporter dry-run safety tests |

Links:
- Full AiOS CI #421: https://github.com/Neuracoderepo1/AiOS/actions/runs/45184608345
- Recovery crypto safety #7: https://github.com/Neuracoderepo1/AiOS/actions/runs/45184608305

The full AiOS CI migration/SQL job included disposable PostgreSQL migration replay and logical export/isolated-restore roundtrip, restoration-role and authorization regressions, Part E audit-anchoring regressions, the 46-case canonical matrix, concurrency/lock-order regressions, and approval-chain post-lock binding revalidation.

## Results and limitations

| Test group | Result | Evidence / limitation |
|---|---|---|
| Exact-head AiOS CI | PASS | Run 45184608345 on exact head `48e1c23c946f96e75d9b60005b140cdbf2102fc9` |
| Exact-head recovery crypto suite | PASS | Run 45184608305 on the same exact head |
| Synthetic PostgreSQL export/restore | PASS | Disposable CI fixture only; not production-equivalent recovery |
| Google Drive upload/download round trip | NOT RUN | No authenticated Drive integration available to this execution environment |
| Owner device FileVault, free space and PostgreSQL inventory | NOT VERIFIED | Owner device is not accessible from this execution environment |
| Production export and isolated production-artifact restore | NOT STARTED | G3 prerequisites remain blocked; no exact-operation authorization recorded |
| Agent 003 independent review | PENDING | Exact-head review requested; no submitted review disposition recorded |

## Evidence integrity and timestamp policy

These workflow conclusions apply only to the exact feature head stated above. Any subsequent commit changes the feature head and requires fresh exact-head workflows before certification. Cancelled or superseded runs are not counted as passes or failures.

Production restore remains NOT STARTED regardless of synthetic CI results. G3 production export remains BLOCKED until owner-side storage/custody/target evidence and Agent 003's independent review are complete, followed by separate exact-operation authorization from the Human Director.
