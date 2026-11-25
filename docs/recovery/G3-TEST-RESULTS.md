# G3 Recovery Test Results

**Evidence refreshed:** 2026-11-25  
**PR:** #43  
**Implementation source revision before this evidence refresh:** `574c662f7f5c4cba32af70dfb3854bcae98181ff`  
**Evidence status:** Updated for Agent 003's REQUEST CHANGES disposition; new security changes require fresh exact-head CI.

## Scope boundary

No production export, production credentials, production database writes, production restore, Google Drive upload, or owner-device inspection was performed. Synthetic test data must never be described as production recovery evidence.

## Agent 003 review and disposition

Agent 003 reviewed PR #43 at exact head `059e63fcdb4457cedc542f4b71b6d6e39e1e389d` and issued **REQUEST CHANGES**. The review confirmed that AiOS CI #426 and recovery crypto #12 passed on that reviewed SHA, independently downloaded and re-hashed both CI artifacts, and reported:
- 109/109 behavioral and 109/109 no-remote tests;
- O1-O7 invariants passed; 23/23 mutants detected;
- terminal/mission-start gap probes 5/5;
- canonical matrix 46/46; smoke self-test 86/86;
- synthetic PostgreSQL export/isolated-restore and preflight 31/31;
- 131 candidate migrations replayed.

The review identified three required corrections:
1. Remote logical exports did not enforce TLS certificate/hostname verification and allowed libpq service/host overrides.
2. Encryption/decryption helpers did not prevent repository-contained or symlink-resolved key/artifact/plaintext paths.
3. This evidence document was stale and did not record the reviewed head, current artifacts or ET27 gap.

The first two findings have now been addressed in the candidate branch:
- Owner-approved remote export now requires `PGSSLMODE=verify-full`, a readable regular non-symlink `PGSSLROOTCERT`, and rejects `PGSERVICE`, `PGSERVICEFILE`, `PGHOSTADDR` and `PGOPTIONS` overrides.
- Shared `path_guard.sh` requires absolute paths, canonicalizes existing paths and output parents, rejects symlinks for existing input/key files, and refuses any recovery input, key, ciphertext or plaintext destination inside the repository.
- Crypto tests now cover relative paths, repository-contained input/key/output paths, symlinked repository parents, remote TLS downgrade and libpq override attempts.
- The earlier checksum-manifest filename-substitution weakness remains fixed and covered by regression testing.

These changes are not certified until the new exact-head workflows pass and Agent 003 reviews the new exact head.

## Automated test commands

Crypto and recovery safety self-tests:

```sh
bash tests/recovery/test_crypto.sh
bash tests/recovery/test_scripts.sh
```

They use only synthetic fixtures and temporary test identities. The exporter dry-run uses inert command stubs and must not invoke a database client.

Disposable PostgreSQL tests require an explicitly disposable local Supabase/PostgreSQL fixture:

```sh
AIOS_TEST_DB_URL='<loopback-only disposable test database>' bash tests/recovery/postgres_roundtrip.sh
AIOS_TEST_DB_URL='<loopback-only disposable test database>' bash tests/recovery/preflight_matrix.sh
```

Never run these PostgreSQL commands with a hosted/production URL. Test scripts must validate loopback and disposable database identity.

## Historical exact-head workflow results

These results apply only to the reviewed SHA `059e63fcdb4457cedc542f4b71b6d6e39e1e389d`; they do not validate the later security changes.

| Workflow | Run | Result | Exact SHA |
|---|---:|---|---|
| Full AiOS CI | #426 / 45226826088 | PASS, 4/4 jobs | `059e63fcdb4457cedc542f4b71b6d6e39e1e389d` |
| Recovery crypto safety | #12 / 45226825896 | PASS, 1/1 job | `059e63fcdb4457cedc542f4b71b6d6e39e1e389d` |

- [Full AiOS CI #426](https://github.com/Neuracoderepo1/AiOS/actions/runs/45226826088)
- [Recovery crypto safety #12](https://github.com/Neuracoderepo1/AiOS/actions/runs/45226825896)

Agent 003 found no ET27 delete-protection or seal-guard run on that reviewed SHA. Those workflows passed on parent PR #42 SHA `fe1fcbea1e9aba02689cb0bb48c0a1180e508504` only. Both ET27 workflows must run successfully on the final PR #43 head.

## Historical uploaded evidence artifacts

The following artifact ZIPs were independently downloaded and SHA-256 re-hashed by Agent 003 for AiOS CI #426:
- `aios-ci-evidence`, artifact ID `14844983580`: `81ecf04fc10972716f6d24600c2838fa97bc33856dbe3db4d1aa5db9ba94effd`.
- `behavioral-evidence`, artifact ID `14843791192`: `456558207797dbc3438cd91e37c3018f02876d576155dc3d492d25ecc4cd31ba`.

These hashes belong to the reviewed SHA above. New artifacts must be captured and independently verified for the final candidate head.

## Current operational results and limitations

| Test / gate | Result | Evidence / limitation |
|---|---|---|
| Reviewed-head AiOS CI #426 | PASS | Historical evidence for `059e63fc...` only |
| Reviewed-head recovery crypto #12 | PASS | Historical evidence for `059e63fc...` only |
| New remote TLS/path-containment changes | PENDING | Await fresh exact-head CI and crypto workflow results |
| ET27 delete-protection on final candidate head | PENDING | Must be triggered and pass on same final SHA |
| ET27 seal-guard on final candidate head | PENDING | Must be triggered and pass on same final SHA |
| Google Drive upload/download round trip | NOT RUN | No authenticated Drive integration available to this execution environment |
| Owner device FileVault, free space and PostgreSQL inventory | NOT VERIFIED | Owner device is not accessible from this execution environment |
| Production export and isolated production-artifact restore | NOT STARTED | G3 prerequisites remain blocked; no exact-operation authorization recorded |
| Agent 003 independent review of updated head | PENDING | Prior disposition was REQUEST CHANGES; fresh review required |

## Evidence integrity and release policy

Any source or documentation commit changes the PR head. Certification evidence must identify the exact same final head across AiOS CI, recovery crypto safety, ET27 delete-protection and ET27 seal-guard. Superseded runs are historical only.

Production restore remains NOT STARTED regardless of synthetic CI results. G3 production export remains BLOCKED until owner-side storage/custody/target evidence, secure transfer and isolated recovery are verified, Agent 003 issues a written approval, and the Human Director separately authorizes the exact production operation. CI success alone is not production authorization.
