# G3 Recovery Test Results

**Evidence refreshed:** 2026-11-25  
**PR:** #43  
**Validated implementation source revision:** `d716ec9823bda3cb12b68bde6b78c334ec5575b0`  
**Source-revision disposition:** all four required automated workflows PASS on `d716ec9...`; the final successor-head evidence and independent review are recorded separately below.

## Scope boundary

No production export, production credentials, production database writes, production restore, Google Drive upload, or owner-device inspection was performed. All automated database tests used disposable local PostgreSQL/Supabase fixtures and synthetic data. Synthetic CI results are not production recovery evidence.

## Agent 003 review findings and remediation

Agent 003 reviewed the earlier candidate `059e63fcdb4457cedc542f4b71b6d6e39e1e389d` and issued **REQUEST CHANGES**. The review identified:
1. Remote logical exports did not enforce TLS certificate/hostname verification and allowed libpq service/host overrides.
2. Encryption/decryption helpers did not prevent repository-contained or symlink-resolved key/artifact/plaintext paths.
3. The evidence record was stale and ET27 workflows had not run on the same candidate SHA.

Remediation implemented in the current source revision:
- Remote owner-approved exports, both production and non-production, require `PGSSLMODE=verify-full` and an absolute, readable, regular, non-symlink `PGSSLROOTCERT` CA file.
- Remote export rejects `PGSERVICE`, `PGSERVICEFILE`, `PGHOSTADDR` and `PGOPTIONS` overrides.
- `NONPRODUCTION` is restricted to loopback. Remote non-production requires the explicit `OWNER_APPROVED_NONPRODUCTION:<approval-id>` marker.
- Export credentials, export destinations, restore source directories, restore credentials, encryption inputs, recipient/identity files, ciphertext, plaintext and checksum-verification inputs must use absolute paths and resolve outside the repository.
- The shared canonical path guard rejects symlinked input/key files, symlinked destination directories, and parent paths that resolve inside the repository. Output directories must already exist; the exporter and age helpers do not create destination directories.
- The checksum verifier binds the manifest to the exact adjacent ciphertext filename and rejects repository-contained paths.
- Restore validation checks PostgreSQL major-version compatibility and exact installed extension versions. Source metadata uses an explicit `|` field separator and the extension inventory uses tab-separated fields.
- Disposable fixtures now pre-create export directories before invoking the hardened exporter.
- Regression tests cover manifest substitution, relative paths, repository-contained paths, symlinked parents, remote TLS downgrade, remote non-production approval, libpq overrides, restore PGPASS symlinks, repository-contained restore paths, and refusal to create missing export destinations.

The earlier review remains a prior disposition only. Agent 003 must independently review the updated source revision and final successor head before certification.

## Automated test commands

Crypto and recovery safety self-tests:

```sh
bash tests/recovery/test_crypto.sh
bash tests/recovery/test_scripts.sh
```

Disposable PostgreSQL tests require an explicitly disposable local Supabase/PostgreSQL fixture:

```sh
AIOS_TEST_DB_URL='<locally started disposable Supabase DB URL>' AIOS_TEST_DB_DESTRUCTIVE_ACK='I_UNDERSTAND_THIS_SCRIPT_CREATES_AND_DROPS_LOCAL_FIXTURE_DATABASES' bash tests/recovery/postgres_roundtrip.sh
AIOS_TEST_DB_URL='<locally started disposable Supabase DB URL>' AIOS_TEST_DB_DESTRUCTIVE_ACK='I_UNDERSTAND_THIS_SCRIPT_CREATES_AND_DROPS_LOCAL_FIXTURE_DATABASES' bash tests/recovery/preflight_matrix.sh
```

Never run these PostgreSQL commands with a hosted/production URL. Test scripts require a per-run destructive-fixture acknowledgement and a loopback URL. Loopback alone does not prove locality because SSH/port-forward tunnels can appear as loopback. CI obtains the URL from the Supabase stack it starts itself; manual use must independently establish that the target is the intended disposable local instance. Never use a hosted URL or tunnel.

## Exact-head automated validation for source revision d716ec9

All four required workflows completed **SUCCESS** on the same exact source SHA `d716ec9823bda3cb12b68bde6b78c334ec5575b0`.

| Workflow | Run | Result | Exact SHA |
|---|---:|---|---|
| Full AiOS CI | #457 / 45670202310 | PASS, 4/4 jobs | `d716ec9823bda3cb12b68bde6b78c334ec5575b0` |
| Recovery crypto safety | #42 / 45670202260 | PASS | same |
| ET27 seal guard | #322 / 45670202306 | PASS | same |
| ET27 delete protection | #322 / 45670202250 | PASS | same |

Run links:
- [Full AiOS CI #457](https://github.com/Neuracoderepo1/AiOS/actions/runs/45670202310)
- [Recovery crypto safety #42](https://github.com/Neuracoderepo1/AiOS/actions/runs/45670202260)
- [ET27 seal guard #322](https://github.com/Neuracoderepo1/AiOS/actions/runs/45670202306)
- [ET27 delete protection #322](https://github.com/Neuracoderepo1/AiOS/actions/runs/45670202250)

### Full AiOS CI evidence

- Behavioral suite: **109 passed, 0 failed**.
- No-remote suite: **109 passed, 0 failed**.
- Edge Function invariants: **O1-O7 passed**.
- Mutation suite: **23/23 mutants detected**, control passes true.
- Mission-start/terminal-mission gap probes: **5 passed, 0 failed**.
- Canonical matrix: **46/46**, including G4 checks 12/12.
- Restore preflight conflict matrix: **31/31**.
- Smoke self-test: **86/86**.
- Disposable PostgreSQL logical export/isolated restore: **PASS**, structural validation passed, source/restored row counts matched.
- Restoration-role and authorization SQL regressions: **PASS**.
- Part E audit anchoring, external verifier and RPC tooling regressions: **PASS**.
- Mission/task, approval-path, reverse-linked approval, audit-lock and cross-organization concurrency checks: **PASS**.
- Approval-chain post-lock binding revalidation: **10/10** successful repetitions, each on a freshly reset and fully migrated disposable PostgreSQL database.
- Candidate migration replay: **131 migrations** applied to disposable CI databases.

### ET27 results

- Seal guard: **303/303 checks passed; 48/48 mutants detected; 0 survived**.
- Delete protection: **66/66 checks passed; 10/10 mutants detected; 0 survived**.
- Both artifacts report 131 migrations replayed and PostgreSQL exit code 0.

## Uploaded evidence artifacts independently re-hashed

The artifact ZIPs were downloaded from GitHub Actions and SHA-256 re-hashed in the execution environment. Computed hashes match the GitHub artifact digests.

| Workflow artifact | Artifact ID | SHA-256 |
|---|---:|---|
| `aios-ci-evidence` | 15050262188 | `b0162c8835416c5c9363e9bb418e5334cceca0b2d9b1197f38ec8c151091edc8` |
| `behavioral-evidence` | 15049286965 | `17d1b975be4fa3a8828a70c167e6bebd2cdfc34d3f95617466e4c3ee473a801c` |
| `et27-seal-guard-evidence` | 15048797931 | `32e917b8dfe62c0c0511c52474a838c0fc0da6ca39862f5994d76c2ab0e02ff3` |
| `et27-delete-protection-evidence` | 15050220329 | `a5de481a6988e4c867bfb0f1777b12a072e2f8ee1b591665e029fe3239152a27` |

## Final successor-head policy

This evidence record is being synchronized with the updated PR #42 hosted-state snapshot and the recovery operating procedures. That documentation/merge commit changes the PR head. Therefore the four exact-head workflows must run again on the resulting final PR #43 head, and Agent 003 must review that final head. The d716ec9 results above remain evidence for the validated source revision only; they must not be relabeled as runs on a later SHA.

## Final successor-head evidence — 25 November 2026

**Exact PR #43 head:** `7b21d92af76876d1d77212285a5a3a9ae207d3cc`  
**Final-head automated workflow gate:** PASS, all four required workflows completed successfully on this identical SHA.  
**Agent 003 disposition:** PARTIALLY ACCEPTED / REQUEST CHANGES. Three findings remain open: destructive fixture target identity/explicit opt-in; standalone validator manifest verification; and this final-head evidence reconciliation. This document now addresses the latter two in the successor candidate; the destructive fixture safeguards have been added in the current successor candidate. A fresh exact-head review is required after the changes and workflows complete.

| Workflow | Run ID | Result | Exact SHA |
|---|---:|---|---|
| AiOS CI #459 | 45673056645 | PASS, 4/4 jobs | `7b21d92af76876d1d77212285a5a3a9ae207d3cc` |
| Recovery crypto #43 | 45673056721 | PASS | same |
| ET27 delete protection #322 | 45673056714 | PASS, 66/66 checks, 10/10 mutants | same |
| ET27 seal guard #322 | 45673056948 | PASS, 303/303 checks, 48/48 mutants | same |

Final-head artifacts independently re-hashed by Agent 003:

| Artifact | ID | SHA-256 |
|---|---:|---|
| `aios-ci-evidence` | 15050933330 | `c28ac366d426f04026c493176d5830edc828af9e96d9eb4c6eab60a4ae48a71c` |
| `behavioral-evidence` | 15051270336 | `2df64ca668043f752a9d46a20363695d366d31dfc1a6c709323cd4212a6083fe` |
| `et27-seal-guard-evidence` | 15050821677 | `b9810c65a060c1ba36c78040fc99e16541ae02cdd0d212b6b0dd38e3aa5c9ce5` |
| `et27-delete-protection-evidence` | 15050338190 | `d3991265912ad2429ec13b32c588fd688a117f5cd3131bb3211b8560cf48c66f` |

The final-head workflow gate is complete. The final-head run evidence does not replace the earlier source-revision evidence, and neither establishes production recovery. Production export/transfer/restore remains **NOT STARTED**. The three Agent 003 findings remain the governing review disposition until a successor is independently reviewed and accepted.

## Current operational results and limitations

| Test / gate | Result | Evidence / limitation |
|---|---|---|
| Source revision d716ec9 automated validation | PASS | Four workflows above, same exact SHA |
| Final successor-head validation (`7b21d92...`) | PASS | Four workflows on identical SHA; artifact hashes independently verified by Agent 003 |
| Agent 003 review of final head (`7b21d92...`) | REQUEST CHANGES | Partially accepted; three findings remain open pending remediation and fresh review |
| Google Drive access, quota, sharing, jurisdiction and retention | NOT VERIFIED | No authenticated Drive connector available to this execution environment |
| Owner device FileVault, free space and PostgreSQL inventory | NOT VERIFIED | Owner device is not accessible from this execution environment |
| Production key generation and custody | NOT STARTED | Must occur on the owner's trusted device |
| Ciphertext-only Drive transfer round trip | NOT RUN | Owner-side authenticated transfer and retrieval evidence absent |
| Production export and isolated production-artifact restore | NOT STARTED | No production data or credentials used |
| Hosted G4 migration | BLOCKED | 14 unapplied candidate migrations and hosted audit/restoration/cron/grant/trigger drift |

## Evidence integrity and release policy

Any source or documentation commit changes the PR head. Certification evidence must identify the exact same final head across AiOS CI, recovery crypto safety, ET27 delete-protection and ET27 seal-guard. Superseded runs are historical only.

Production restore remains NOT STARTED regardless of synthetic CI results. G3 production export remains BLOCKED until owner-side storage/custody/target evidence, secure transfer and isolated recovery are verified, Agent 003 issues a written approval, and the Human Director separately authorizes the exact production operation. CI success alone is not production authorization.
