# G3 Recovery Test Results

**Evidence date:** 2026-11-23  
**PR:** #43  
**Exact validated feature head:** `02b6eb3b2fd4453a436d82ea1c15ccd239bd8959`

## Scope boundary

No production export, production credentials, production database writes, production restore, Google Drive upload, or owner-device inspection was performed. Synthetic test data must never be described as production recovery evidence.

## Automated test commands

The crypto self-test command is:

```sh
bash tests/recovery/test_crypto.sh
```

It requires `age` and standard shell utilities. It creates only a temporary synthetic payload and temporary test identities. Coverage includes:
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
| Full AiOS CI | #423 / 45223474353 | PASS | All four jobs: functions typecheck, evidence integrity, behavioral suite, migrations and SQL tests |
| Recovery crypto safety | #9 / 45223474539 | PASS | Synthetic encryption/decryption, tamper, key, manifest and exporter dry-run safety tests |

Links:
- Full AiOS CI #423: https://github.com/Neuracoderepo1/AiOS/actions/runs/45223474353
- Recovery crypto safety #9: https://github.com/Neuracoderepo1/AiOS/actions/runs/45223474539

The full AiOS CI migration/SQL job included disposable PostgreSQL migration replay and logical export/isolated-restore roundtrip, restoration-role and authorization regressions, Part E audit-anchoring regressions, concurrency/lock-order regressions, and approval-chain post-lock binding revalidation across 10 fresh migrated databases.

## Uploaded evidence artifacts

These artifacts were uploaded by the exact-head CI #423 run:
- `aios-ci-evidence`: GitHub-reported SHA-256 `4d4a25302d5d17a79261870a92874aaede01033fada58c420a3fc508b5b3776d`.
- `behavioral-evidence`: GitHub-reported SHA-256 `6ee1e33076a6d89df9c305e647072c128a9957f6ae256c6f6a6d0f4c3687b408`.

These are GitHub-reported artifact digests. No independent artifact ZIP download and re-hash is claimed here.

## Results and limitations

| Test group | Result | Evidence / limitation |
|---|---|---|
| Exact-head AiOS CI | PASS | Run 45223474353 on exact head `02b6eb3b2fd4453a436d82ea1c15ccd239bd8959` |
| Exact-head recovery crypto suite | PASS | Run 45223474539 on the same exact head |
| Synthetic PostgreSQL export/restore | PASS | Disposable CI fixture only; not production-equivalent recovery |
| Google Drive upload/download round trip | NOT RUN | No authenticated Drive integration available to this execution environment |
| Owner device FileVault, free space and PostgreSQL inventory | NOT VERIFIED | Owner device is not accessible from this execution environment |
| Production export and isolated production-artifact restore | NOT STARTED | G3 prerequisites remain blocked; no exact-operation authorization recorded |
| Agent 003 independent review | PENDING | Exact-head review requested; no submitted review disposition recorded |

## Evidence integrity and timestamp policy

These workflow conclusions apply only to the exact feature head stated above. Any subsequent commit changes the feature head and requires fresh exact-head workflows before certification. Cancelled or superseded runs are not counted as passes or failures.

Production restore remains NOT STARTED regardless of synthetic CI results. G3 production export remains BLOCKED until owner-side storage/custody/target evidence and Agent 003's independent review are complete, followed by separate exact-operation authorization from the Human Director.
