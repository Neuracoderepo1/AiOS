# AiOS budget-neutral release closure checkpoint

> **Authoritative update 2026-11-19:** Earlier sections are preserved as historical checkpoints. They are superseded for current-state facts by Section 17. The current candidate inventory is 129 migration files versus 117 hosted-applied versions (12 unapplied), not the historical 128/117/11 figures. The reviewed implementation baseline is PR #35 head 318f561a475a23e731e8d4e8d55ffb1d9d49075c. A successor commit adds security-boundary regression coverage and documentation; it requires fresh exact-head CI before acceptance.

> **Authoritative update 2026-11-22:** Section 21 at the end of this document supersedes the 2026-11-19 banner above for current-state facts. The current candidate inventory is 131 migration files versus 117 hosted-applied versions (14 unapplied), and the PR #40 evidence SHA is `03495472bf7ec40a2ca4e4fec8e63fb42a34224e`. The 129/117/12 figures and the PR #35 baseline named above are historical. Earlier text is preserved and not rewritten.

**Inspection date:** 2026-11-13  
**Historical candidate at start of inspection:** `13394941bc31a8005777ee40cf0ce87115e6783a`  
**Latest reviewed implementation head:** `0bf79e798f01b77ad665fc1e71873b29c104e5b7`  
**Follow-up branch:** `agent004/restore-preflight-docs-closure`  
**PR:** [#35](https://github.com/Neuracoderepo1/AiOS/pull/35)  
**Hosted project:** `jtkcdwhiduixoiodhbfn` (Project AiOS, PostgreSQL 17.6, eu-west-1)

This is an evidence checkpoint, not a production certification or deployment authorization. Hosted inspection was read-only. The only repository change associated with this checkpoint is the correction of the stale current-state document; it does not modify migrations or application behavior.

## 1. Candidate and CI baseline

At inspection start, PR #35 was open, draft, unmerged, and pointed to the expected candidate SHA `13394941bc31a8005777ee40cf0ce87115e6783a`. Agent 003's source-review disposition for F-2 and the P1 quarantine-enforcement finding remains CLOSED; production certification remains WITHHELD.

All three required workflows were completed successfully on that exact SHA:

| Workflow | Run ID | Result |
|---|---:|---|
| AiOS CI | [43306638907](https://github.com/Neuracoderepo1/AiOS/actions/runs/43306638907) | success, 4/4 jobs |
| ET27 delete protection | [43306638968](https://github.com/Neuracoderepo1/AiOS/actions/runs/43306638968) | success |
| ET27 seal guard | [43306638875](https://github.com/Neuracoderepo1/AiOS/actions/runs/43306638875) | success |

The AiOS CI jobs included full migration replay, SQL regressions, restoration-role authorization, audit anchoring, the 46-case canonical matrix, expiry and mission/task concurrency, approval lock-order races, cross-organization audit-lock tests, behavioral tests, type-checking, and evidence-integrity checks. Existing recorded totals remain: behavioral 97/97, no-remote behavioral 97/97, mutation 23/23, canonical matrix 46/46, smoke self-test 86/86, ET27 delete protection 66 checks with 10/10 mutants detected, and ET27 seal guard 303 checks with 48/48 mutants detected.

GitHub artifact metadata still reports these exact SHA-256 digests:

| Artifact | ID | SHA-256 |
|---|---:|---|
| AiOS CI evidence | 13984611744 | `149f7908a02c5dbee4f0e6a6425d876292274c3aab2babb8488d2afc0b6a7df1` |
| Behavioral evidence | 13983873151 | `5e85893da8b7ed72f1e57095dcea9966d3c49a4a8cd3dd9f6efa4f3ca0b94ac1` |
| ET27 delete protection | 13983907559 | `aa0a6f587a61a70d87961d80a249d428586a0433707e6579dcc5c48244d30e6d` |
| ET27 seal guard | 13983698203 | `274be04c65324acb17ddb2cd4ebb3e585a4288209d1c0a3c7772e3d63f843084` |

These artifacts are tied to the candidate SHA above. A subsequent documentation commit creates a new candidate and requires fresh exact-head CI before it can be treated as validated.

## 2. Migration parity matrix

Hosted migration history returned 117 applied versions, latest `20261108130000`. The candidate tree contains 128 SQL migration files. The 11 versions below are present in the candidate tree and absent from hosted migration history.

| Version | Candidate migration | Hosted state | Required action | Deployment prerequisite / rollback |
|---|---|---|---|---|
| 20261108140000 | aios_execution_lock_order_and_task_terminal_cascade | unapplied | Review lock-order and terminal cascade parity | Owner-approved staged migration plan; rollback assessed per DDL/data effect |
| 20261108150000 | aios_approval_paths_global_lock_order | unapplied | Review approval-path lock-order parity | Same |
| 20261109120000 | aios_restoration_part_d | unapplied | Provision/validate restorer role, restoration state machine, ALWAYS audit triggers, and narrowed service-role grants | Owner-approved executor/role boundary and independently validated recovery path; no automatic reverse assumed |
| 20261109130000 | aios_audit_anchoring_part_e | unapplied | Install canonical audit anchor/verifier structures and schedule dependencies | External TSA/trust-root availability is separately blocked; rollback must preserve audit evidence |
| 20261110100000 | aios_batch_prelock_before_audit | unapplied | Review batch lock ordering | Repeatable real-PostgreSQL race evidence and migration plan |
| 20261111170000 | aios_shared_approval_invocation_resolver | unapplied | Review shared resolver behavior and grants | Owner-approved migration window and tested forward recovery |
| 20261111190000 | aios_restorer_allowlist_and_mission_reconciliation | unapplied | Validate complete restorer membership allowlist and reconciliation queue | Approved migration executor identity and role catalog preflight |
| 20261111200000 | aios_mission_reconciliation_schedule_registry | unapplied | Register mission reconciliation schedule metadata | Confirm cron extension and endpoint/secret configuration |
| 20261111210000 | aios_register_mission_reconciliation_trigger | unapplied | Register reconciliation trigger | Confirm preceding schema/function dependencies |
| 20261111220000 | aios_approval_binding_and_audit_lock_order | unapplied | Validate approval binding and audit lock ordering | Repeatable PostgreSQL concurrency acceptance |
| 20261111230000 | aios_reaper_per_record_isolation | unapplied | Install F-2 per-record isolation and durable quarantine | Agent 003 review and separately authorized hosted migration |

**Evidence:** Supabase migration-history listing for project `jtkcdwhiduixoiodhbfn`; Git tree at candidate SHA; AiOS CI migration replay job in run `43306638907`.

**Important distinction:** CI proves the complete candidate migration tree replays on a disposable local Supabase/PostgreSQL environment. It does not prove that replaying the missing migrations against the hosted database is safe, nor that the live catalog is identical to the candidate schema. No missing migration was applied.

### Catalog parity observations

| Area | Hosted observation | Candidate intent / gap |
|---|---|---|
| Restorer role | `aios_restorer` absent | Part D and later allowlist migrations not applied |
| Audit protection triggers | Four `public.aios_audit_events` protection triggers report `tgenabled = 'O'` (ORIGIN) | Part D changes the four audit triggers to ENABLE ALWAYS |
| Audit table grants | `service_role` has SELECT, INSERT, UPDATE, DELETE, REFERENCES, TRIGGER; no TRUNCATE | Part D retains SELECT/INSERT and revokes UPDATE/DELETE/TRUNCATE/TRIGGER/REFERENCES |
| Cron | Two active schedules: stale-task reaper and stale-approval expiry | Candidate also contains later audit/reconciliation schedule registration; not yet hosted |
| RLS | 17 public tables and one private table were observed with RLS enabled; FORCE RLS is false | Ownership and owner-bypass behavior require policy-aware review; no blanket FORCE RLS change is proposed |
| SECURITY DEFINER | The inspected public/private SECURITY DEFINER routines have `search_path = ''` and postgres ownership | Full function-definition/hash parity against candidate source remains incomplete |
| Owner verifier | SQL session has database role postgres but no authenticated owner JWT context | Genuine owner-session audit-chain verification remains NOT VERIFIED |

The hosted trigger and grant differences are material. They must not be silently normalized by an ad-hoc hosted command. Part D is the candidate's controlled migration path; Agent 003 must review the migration sequence and rollback/recovery prerequisites before any owner-authorized deployment decision.

## 3. Audit security

Read-only hosted catalog inspection confirmed:
- Four audit protection triggers exist: hash append, immutable update, immutable delete, and no-truncate.
- All four are currently ORIGIN-enabled, not ALWAYS-enabled.
- `service_role` lacks TRUNCATE but retains UPDATE, DELETE, and TRIGGER in addition to SELECT/INSERT.
- The connected SQL identity cannot prove owner-context authorization for `private.verify_audit_chain`; `auth.uid()` is not an authenticated owner identity in this connection.

The candidate Part D migration directly addresses the trigger mode and service-role privilege discrepancy. No hosted grants, trigger modes, or RLS settings were changed. A genuine authenticated owner must run the owner-context verifier for each relevant organization and provide output that includes scope, timestamp, and result but no credentials or tokens.

## 4. GitHub branch protection

Read-only GitHub branch metadata reports:
- `main` is protected.
- Required status checks: `evidence-integrity`, `functions-typecheck`, and `migrations-and-sql-tests`.
- Reported enforcement level: `non_admins`.
- Repository rulesets endpoint returned an empty list.

The dedicated branch-protection endpoint returned HTTP 403 for the connected integration. Therefore the integration cannot authoritatively inspect all protection fields. The empty repository rulesets result does not establish that inherited organization rulesets are absent.

The repository contains `.github/CODEOWNERS` entries for integrity tests, the matrix manifest, testing evidence, and the CI workflow. The existence of CODEOWNERS does not prove that GitHub is configured to require code-owner review.

**Owner evidence still required:** export/screenshots from repository Settings and organization Rulesets showing required approving reviews, CODEOWNERS enforcement, stale-review dismissal, force-push/deletion restrictions, bypass actors, administrator exemptions, enforcement mode, and target branch scope.

## 5. Backup and recovery

Owner evidence confirms the project is on Supabase Free:
- Scheduled project backups are not included.
- Daily backups are included with Pro.
- PITR requires Pro plus a paid add-on, reported by the owner at US$100/month.
- No managed backup timestamp, recoverable range, or successful restore test has been evidenced.
- RPO/RTO are not defined or measured.

This is a paid-tier limitation for managed backup/PITR, not a code defect. Do not purchase an upgrade.

**Budget-neutral engineering work still outstanding:** implement and test a controlled logical schema/data export workflow and an isolated local restore/validation workflow using approved tooling. The scripts must fail closed on nonzero export status, empty/invalid dump, missing required extensions, checksum mismatch, or failed restore validation. Credentials must be supplied through environment variables or a secure prompt, never command-line literals, logs, or committed files. Production data must not be exported into this repository. Until a genuine owner-authorized export and successful isolated restore are performed, no production backup or restore readiness may be claimed.

## 6. Documentation correction

The previous `docs/operations/current-state.md` described a historical 96-migration baseline. It has been corrected to identify the current candidate as 128 files and the hosted history as 117 applied, and to distinguish clean-room CI replay from hosted schema parity.

## 7. Findings register

| Finding | Classification | Current disposition |
|---|---|---|
| PR #35 F-2/P1 source findings | A. CLOSED | Agent 003 source disposition closed; production certification still withheld |
| Exact-head CI on starting candidate | A. CLOSED | Three workflows green; artifact digests recorded above |
| Stale current-state migration count | A. CLOSED | Documentation corrected in this checkpoint commit; new SHA requires fresh CI |
| 11 hosted migrations unapplied | B. OWNER ACTION REQUIRED | Requires owner-approved migration plan; no hosted application authorized |
| Hosted audit trigger mode and service-role grants differ from candidate | B. OWNER ACTION REQUIRED | Candidate migration exists; hosted correction requires separately approved migration |
| Hosted restorer role absent | B. OWNER ACTION REQUIRED | Part D provisioning requires approved migration executor and owner-controlled role boundary |
| Owner-session audit verification | B. OWNER ACTION REQUIRED | Genuine authenticated owner session required |
| Branch-protection full detail | D. EXTERNAL PLATFORM LIMITATION | Dedicated endpoint 403; owner-level export required |
| Managed scheduled backups/PITR on Free | C. PAID-TIER / BUDGET BLOCKED | Pro and PITR add-on are paid; no purchase authorized |
| Logical export + isolated restore scripts and test | E. ENGINEERING BLOCKED | Budget-neutral implementation and reproducible local validation remain outstanding |
| Full catalog definition/hash parity | E. ENGINEERING BLOCKED | Function definitions, grants, triggers, indexes, constraints and extension dependencies need a complete machine-readable comparison |
| External TSA/RFC3161 anchoring | D. EXTERNAL PLATFORM LIMITATION | Part E documents the external trust dependency; no TSA/trust roots evidenced |

## 8. Safety and governance confirmation

This checkpoint used read-only hosted database inspection and read-only GitHub metadata/file inspection, plus a documentation-only commit on the existing PR #35 branch. No hosted migration, production write, grant/role/RLS/trigger/cron change, deployment, backup, restore, plan upgrade, billing change, or merge was performed. PR #35 remains draft and unmerged. PR #34 remains untouched. No Armadillon or Arbitron repository was accessed or changed.

## 9. Agent 003 review request

Agent 003 is requested to independently review:
1. The updated current-state document and this checkpoint.
2. The migration parity inventory and the 11-version hosted gap.
3. The hosted audit trigger/grant observations and the candidate Part D corrective migration.
4. The classification of owner, external-platform, paid-tier, and engineering blockers.
5. The exact-head CI and artifact evidence after this documentation commit completes fresh CI.

Agent 004 does not self-certify production readiness. Production certification remains withheld until Agent 003 independently reviews the final candidate and all owner/platform dependencies are resolved or explicitly accepted under an authorized release decision.


## 10. Supplemental engineering execution — logical export and restore

After the initial checkpoint, Agent 004 added the following repository artifacts:

| Path | Purpose |
|---|---|
| `scripts/recovery/export_logical.sh` | Approval-gated pg_dump custom archive, schema-only export, extension/source inventory, archive listing, and SHA-256 manifest |
| `scripts/recovery/restore_local.sh` | Checksum-verified restore into an empty loopback-only `aios_restore_*` database |
| `scripts/recovery/validate_local_restore.sh` | Structural validation of application tables, RLS, audit triggers, verifier presence, and extension inventory |
| `tests/recovery/test_scripts.sh` | Shell syntax and fail-closed guard tests |
| `docs/operations/LOGICAL-EXPORT-RESTORE.md` | Operator runbook, data handling, prerequisites, limitations, restore evidence and cleanup |
| `.github/workflows/ci.yml` | Runs the recovery script safety self-tests in the migrations/SQL CI job |

The exporter requires an explicit `NONPRODUCTION` marker restricted to loopback, or an `OWNER_APPROVED_NONPRODUCTION:<approval-id>` / `OWNER_APPROVED_PRODUCTION:<approval-id>` marker for remote sources. It rejects remote `PGHOSTADDR` and libpq service overrides for loopback non-production exports, reads secrets only through libpq's protected `PGPASSFILE`, and refuses output inside the repository. The production marker is a guardrail, not a substitute for owner approval. No production export was performed. The restore script accepts only loopback targets and a database name prefixed `aios_restore_`, validates checksums, rejects non-system user schemas and pre-existing public relations of every relkind (including partitioned tables), routines, and user-defined types, and runs `pg_restore` in a single transaction. It never drops target objects. The new PostgreSQL roundtrip tests create a custom schema and a partitioned table in separate disposable targets, assert both restores are rejected by the preflight, and assert both original objects remain present.

**Verification boundary:** The fail-closed self-test and synthetic real-PostgreSQL export/restore cycle passed on the previous reviewed head. The additional custom-schema and partitioned-table negative cases are now part of the follow-up and await fresh exact-head CI. The validator is structural only; it does not by itself prove audit-chain integrity, owner-context authorization, cron reconstruction, application behavior, or measured recovery objectives. Therefore logical recovery is **PARTIALLY IMPLEMENTED / ENGINEERING VERIFICATION PENDING**, not CLOSED.

## 11. Supplemental hosted catalog inventory

A focused read-only catalog summary on 2026-11-13 returned:
- PostgreSQL 17.6; database role `postgres`; `auth.uid() = NULL`.
- 70 public/private functions; 48 SECURITY DEFINER. All inspected SECURITY DEFINER functions are postgres-owned, use `search_path = ''`, and have no PUBLIC or anon EXECUTE. Five have authenticated EXECUTE and 14 have service_role EXECUTE; these require per-function intent review.
- 18 public/private application tables, all RLS-enabled; zero FORCE RLS; 38 policies.
- Seven installed extensions: pg_cron 1.6.4, pg_jsonschema 0.3.3, pg_stat_statements 1.11, pgcrypto 1.3, plpgsql 1.0, supabase_vault 0.3.1, uuid-ossp 1.1.
- Four audit-table protection triggers remain ORIGIN-enabled. `service_role` retains SELECT, INSERT, UPDATE, DELETE, REFERENCES, TRIGGER; no TRUNCATE.
- Two active cron jobs only: `aios-reap-stale-tasks` and `aios-expire-stale-approvals`, both every five minutes.
- `aios_restorer` remains absent.

This inventory improves observability but is not full function-body/hash parity. Full candidate-versus-hosted catalog comparison and function-level grant-intent reconciliation remain engineering work.

## 12. Current candidate CI boundary

The implementation head reviewed by Agent 003 was `0bf79e798f01b77ad665fc1e71873b29c104e5b7`. Its three exact-head workflows passed: AiOS CI 43348478340, ET27 delete protection 43348478449, and ET27 seal guard 43348478353. GitHub artifact metadata for that head reported: AiOS CI evidence artifact 14002338583 SHA-256 `062c1de4d48134d3ec6599fb7a86678dd90d359f6837f2470c266946f6f3725e`; behavioral evidence artifact 14002323186 SHA-256 `c0c3355dabb77864493afd013083a9dc1cd63a76f67f38c2333d95caf7fcfea7`; ET27 delete-protection artifact 14002318574 SHA-256 `b09aaa5e76d161420367a333613912e16d34ae7918df4c911065c251fe171d37`; ET27 seal-guard artifact 14001844269 SHA-256 `2c0f875215a1e491d564868aacaffeffd682a05eaf128c73fbe2780b2e6f1e94`. The current follow-up branch adds a stricter restore target preflight, negative real-PostgreSQL tests for a pre-existing custom schema and partitioned table (including non-modification assertions), and this documentation refresh. Its exact-head CI has not yet run; no claims of success are made until all three workflows complete against the new commit SHA.

## 13. Updated findings register

| Finding | Classification | Current disposition |
|---|---|---|
| F-2/P1 source review | A. CLOSED | Agent 003 source disposition remains accepted; production certification withheld |
| Stale migration count | A. CLOSED | Corrected current-state document |
| Recovery scripts and operator runbook | A. CLOSED for repository mechanics | Safety self-tests and synthetic real-PostgreSQL export/restore roundtrip passed; production recovery readiness remains unverified |
| Exact-head CI for implementation candidate | A. CLOSED | All three workflows passed on SHA `16c65b8d5bb730d8813124c39a6276df53ea721c`; docs-only follow-up will receive its own CI |
| 11 unapplied hosted migrations and catalog drift | B. OWNER ACTION REQUIRED | Requires separately approved migration plan |
| Owner-context audit verification | B. OWNER ACTION REQUIRED | Genuine authenticated owner session required |
| Full branch-protection evidence | B/D. OWNER ACTION / EXTERNAL LIMITATION | Owner export required; dedicated endpoint returns 403 |
| Supabase managed backups/PITR | C. PAID-TIER / BUDGET BLOCKED | Current Free plan excludes scheduled backups; PITR requires paid plan/add-on |
| Full function definition/hash parity and grant-intent review | E. ENGINEERING BLOCKED | Aggregate catalog captured; exact source-to-hosted parity remains to be completed |
| Synthetic real-PostgreSQL export/restore acceptance | A. CLOSED | Disposable local source/target roundtrip passed with checksums, structural checks, and row-count parity; full hosted restore remains an owner/environment dependency |
| External TSA/RFC3161 trust anchor | D. EXTERNAL PLATFORM LIMITATION | Provider/trust-root dependency remains |



### Recovery guard hardening follow-up

The export approval gate was tightened after source inspection: the bare `NONPRODUCTION` marker is accepted only for loopback sources and is rejected if `PGHOSTADDR`, `PGSERVICE`, or `PGSERVICEFILE` could redirect the connection. Remote non-production and production exports require an explicit approval identifier. The local restore and validator reject remote `PGHOST`/`PGHOSTADDR`, reject libpq service overrides, and verify the password file is present with permissions 0600 or stricter. Safety tests now include these negative cases. These checks are code-level guardrails; they do not replace independent approval or a real PostgreSQL restore test.


## 14. Historical implementation-candidate CI and artifact evidence

Implementation candidate: `16c65b8d5bb730d8813124c39a6276df53ea721c`

| Workflow | Run ID | Conclusion |
|---|---:|---|
| AiOS CI | 43346710190 | success |
| ET27 delete protection | 43346709899 | success |
| ET27 seal guard | 43346710291 | success |

Downloaded ZIP artifacts and independently recomputed SHA-256:

| Artifact | ID | SHA-256 |
|---|---:|---|
| Behavioral evidence | 14002126505 | `54b21a3a987e5db9fd57f8a74dccde93252cd13e0f3f70bacc7a66396dabe0c2` |
| AiOS CI evidence | 14001628833 | `617b1c4862df239b66e4c67a318c81ce53fe0091f787e6e28c255f4da1b7f60b` |
| ET27 delete protection | 14001174550 | `ece3d8961e67a07454bfaa85b81400ab720c91218a93e642e1046933162a34db` |
| ET27 seal guard | 14001029933 | `a19d032b0f75eb20e62879953d89ddcdbe1e5c04665375cebf27a005503ee289` |

All four local SHA-256 computations matched GitHub artifact metadata. AiOS CI included the real PostgreSQL roundtrip and all existing regression/concurrency suites. The candidate passed 46/46 canonical matrix cases, 97/97 behavioral and no-remote tests, 23/23 mutation tests, 5/5 gap probes, three F-2 repetitions, and 86/86 smoke tests.

Production certification remains withheld. Agent 003 independent review is requested; no formal review has been recorded at this checkpoint.


## 15. Agent 003 follow-up closure — 13 November 2026

**Last independently reviewed implementation baseline:** `40f80035e43e12604ad326388772008017171dbf`.

All three workflows passed on that exact baseline:

| Workflow | Run ID | Result |
|---|---:|---|
| AiOS CI | 43404925437 | success, 4/4 jobs |
| ET27 delete protection | 43404925475 | success |
| ET27 seal guard | 43404925438 | success |

The four artifacts were downloaded and inspected; independently computed SHA-256 values matched GitHub metadata:

| Artifact | ID | SHA-256 |
|---|---:|---|
| AiOS CI evidence | 14026927672 | `9932989e494a90796f31741194da45de7a8384a95493ae8608b6b25568106107` |
| Behavioral evidence | 14026223969 | `81d639dc68f19c2e032a93ed7a639a627e0b6565cdb036cbdb054fb06451207a` |
| ET27 delete protection | 14026792248 | `32ec854a7eb9d57cc139bf115327a1ed563068075c1668c1cadbd9b3a6f9baf6` |
| ET27 seal guard | 14027036762 | `406bb6180a57a252edbadda05605f40f8199bc65f4158465adc7b7d12f673c9f` |

### D1 — restore target preflight and atomicity

The preflight contract is explicitly narrowed to enumerated namespace-local classes. It checks non-system schemas except the standard `public` schema itself; every public relation kind; routines; user-defined types; collations; conversions; operators; operator classes/families; text-search configurations, dictionaries, parsers and templates; and extended statistics. Extension-owned objects are excluded to avoid false positives from installed extensions. The runbook lists non-enumerated database-level classes, including extensions, event triggers, publications/subscriptions, foreign data wrappers/servers, user mappings, casts, transforms, languages, default privileges and roles.

The restore remains non-destructive and uses `pg_restore --exit-on-error --single-transaction`. In addition to the preflight rejection tests for a pre-existing custom schema and partitioned table, the follow-up real-PostgreSQL regression deliberately bypasses only the preflight, creates a duplicate-relation conflict after earlier archive objects have begun restoring, and asserts that the earlier schema/extension are rolled back while the pre-existing table and its sentinel row remain unchanged. This is synthetic disposable-database evidence only. Fresh CI on the successor commit is required before D1 is marked accepted.

### D2 — documentation reconciliation

This checkpoint and `docs/operations/current-state.md` now identify `40f80035...` as the last independently reviewed baseline, preserve its exact workflow/artifact evidence, and explicitly distinguish that baseline from the new unverified documentation/test successor. The successor's exact SHA is the current PR #35 head and must be taken from GitHub after the final commit; no prior SHA's CI is substituted.

### Release boundary remains unchanged

Production certification remains **WITHHELD / NOT CERTIFIED**. The 11 unapplied hosted migrations, audit trigger/grant drift, missing hosted restorer role, owner-context verification, branch-governance evidence, complete source-to-hosted function parity, production recovery exercise, measured RPO/RTO, and external TSA/trust-root dependency remain open. No hosted migration, production write/export/restore, deployment, billing change, paid upgrade, or merge is authorized by this checkpoint. PR #35 must remain draft and unmerged pending fresh exact-head CI and independent Agent 003 review.

## 16. Exact-head engineering and documentation checkpoint — 13 November 2026

**Implementation SHA with completed exact-head CI:** `54a8bfc9daf5638fc25654acb937c6737c6f80d2`  
**Documentation successor at this checkpoint:** `b6cee309b532256b863b4648167c62c18ccc71ab` (its own exact-head CI is running; this SHA is superseded by the commit containing this update)  
**Branch:** `agent004/f2-reaper-record-isolation`  
**Status at this checkpoint:** PR #35 is draft, open, and unmerged. This section supersedes earlier statements in this document that the current successor SHA was unknown or that the approval-chain concurrency test was still failing. Earlier candidate records remain historical and are not substituted for this exact-head evidence.

### Exact-head workflow results

All three required workflows completed successfully against the same exact SHA `54a8bfc9daf5638fc25654acb937c6737c6f80d2`:

| Workflow | Run ID | Result |
|---|---:|---|
| AiOS CI | [43431423424](https://github.com/Neuracoderepo1/AiOS/actions/runs/43431423424) | SUCCESS, 4/4 jobs |
| ET27 delete protection | [43431423482](https://github.com/Neuracoderepo1/AiOS/actions/runs/43431423482) | SUCCESS |
| ET27 seal guard | [43431423441](https://github.com/Neuracoderepo1/AiOS/actions/runs/43431423441) | SUCCESS |

The approval-chain binding revalidation script was restored to its complete intended test body and hardened so failure diagnostics survive cleanup. On this candidate, shell syntax validation and ShellCheck passed. The forced lock interleaving passed ten consecutive repetitions, each after an independent local database reset and full migration replay. In all ten repetitions, the task-binding change committed while the worker was waiting; the worker rejected the stale snapshot with SQLSTATE `40001`. The targeted PostgreSQL sessions were absent after cleanup in every repetition.

The AiOS CI evidence also reports the smoke self-test at 86/86, mutation detection at 23/23, and known-gap probes at 5/5. These are engineering test results, not proof of hosted production parity or recovery readiness.

### Exact-head artifact inventory

GitHub artifact metadata binds each artifact to the exact SHA above and reports these SHA-256 digests:

| Evidence | Artifact ID | SHA-256 |
|---|---:|---|
| AiOS CI evidence | 14040084106 | `3efe82421652cee2175721419a48e4ae75ea2cd944fca2ac0b01ffa67d4d11f7` |
| Behavioral evidence | 14040206839 | `7afe6451883fe0bad9591d15a47fa331d968aa80f047c0d1c073a49d4b1264e2` |
| ET27 delete protection | 14038728179 | `96ab35644b7f2cfa402e311f283bce9d04952ca23c9f0f875fcb3327495063e0` |
| ET27 seal guard | 14040326910 | `bf9bc571be9e7d810bd08655adc631703e38a730705e981ef1ae68f9c8e724a9` |

The artifact records identify branch `agent004/f2-reaper-record-isolation` and head SHA `54a8bfc9daf5638fc25654acb937c6737c6f80d2`. These digests are the GitHub-reported artifact digests; do not describe them as independently recomputed local ZIP hashes unless a separate download-and-hash record is attached.

### Agent 003 review boundary

The successful exact-head workflows and repeated concurrency test establish the engineering evidence for this candidate. They do **not** themselves constitute Agent 003 independent certification. Agent 003 must review the exact SHA, the concurrency script and its ten-run evidence, the workflow logs, and the four artifact records, then record a distinct disposition. Until that review is recorded, the current successor is **AWAITING AGENT 003 EXACT-HEAD REVIEW**.

### Production boundary and outstanding blockers

Production certification remains **WITHHELD / NOT CERTIFIED**. The following remain open and must not be represented as closed by CI success:

- 11 candidate migrations remain unapplied to the hosted project.
- Four hosted audit protection triggers remain ORIGIN-enabled; hosted `service_role` retains broader audit-table grants than candidate intent.
- Hosted `aios_restorer` role is absent.
- Authenticated owner-context audit verification is not evidenced.
- Required-review/CODEOWNERS and complete branch-governance enforcement evidence remains incomplete.
- Full candidate-to-hosted function-definition/hash parity and function-level grant-intent reconciliation remain incomplete.
- Hosted cron/reconciliation parity remains incomplete.
- No production export and isolated production-copy restore, secrets/Edge Function/cron reconstruction, or application acceptance exercise is evidenced.
- Managed backups/PITR remain unavailable on the current Free plan; no paid upgrade is authorized.
- Measured RPO/RTO and external TSA/RFC3161 trust-root lifecycle remain unproven.

No hosted migration, production write/export/restore, role/grant/RLS/trigger/cron change, deployment, billing change, paid upgrade, or merge is authorized by this checkpoint. Keep PR #35 draft and unmerged. Scope remains AiOS only; Armadillon and Arbitron are excluded.

### Documentation successor rule

This checkpoint is written on the PR branch. Its commit creates a new candidate SHA. The three required workflows must run again against the final documentation commit SHA, and Agent 003 must review that exact final SHA. The successful runs listed above validate implementation SHA `54a8bfc9...` only; they do not certify a later documentation-only commit.


## 17. Authoritative reconciliation — 19 November 2026

**Reviewed implementation baseline:** 318f561a475a23e731e8d4e8d55ffb1d9d49075c  
**Branch:** agent004/f2-reaper-record-isolation  
**PR:** [#35](https://github.com/Neuracoderepo1/AiOS/pull/35), open, draft, unmerged  
**Hosted project:** jtkcdwhiduixoiodhbfn, PostgreSQL 17.6  
**Release disposition:** **PRODUCTION CERTIFICATION WITHHELD / NOT CERTIFIED**

### 17.1 Corrected migration inventory

A fresh recursive tree inventory of the PR #35 candidate contains **129 SQL migration files**. A fresh read-only query of supabase_migrations.schema_migrations returned **117 hosted migrations**, latest 20261108130000. The current difference is **12 unapplied candidate migrations**, not the historical 11:

| Version | Migration | Status |
|---|---|---|
| 20261108140000 | aios_execution_lock_order_and_task_terminal_cascade | Not applied |
| 20261108150000 | aios_approval_paths_global_lock_order | Not applied |
| 20261109120000 | aios_restoration_part_d | Not applied |
| 20261109130000 | aios_audit_anchoring_part_e | Not applied |
| 20261110100000 | aios_batch_prelock_before_audit | Not applied |
| 20261111170000 | aios_shared_approval_invocation_resolver | Not applied |
| 20261111190000 | aios_restorer_allowlist_and_mission_reconciliation | Not applied |
| 20261111200000 | aios_mission_reconciliation_schedule_registry | Not applied |
| 20261111210000 | aios_register_mission_reconciliation_trigger | Not applied |
| 20261111220000 | aios_approval_binding_and_audit_lock_order | Not applied |
| 20261111230000 | aios_reaper_per_record_isolation | Not applied |
| 20261113160000 | aios_reaper_fail_closed_hardening | Not applied |

The migration replay is green on the disposable CI database. No hosted migration was applied. Candidate-to-hosted schema/function/grant parity remains unproven.

### 17.2 Exact-head engineering and Agent 003 disposition

On exact SHA 318f561a475a23e731e8d4e8d55ffb1d9d49075c, all required workflows completed successfully:

| Workflow | Run ID | Result |
|---|---:|---|
| AiOS CI | 43468907258 | SUCCESS, 4/4 jobs |
| ET27 delete protection | 43468907181 | SUCCESS |
| ET27 seal guard | 43468907207 | SUCCESS, retry attempt 2 |

Agent 003 independently revalidated this exact head on 16 November. The F-2 per-record reaper engineering behavior remains accepted. Agent 003 did **not** certify production and explicitly required PR #35 to remain draft and unmerged. Artifact records: AiOS CI 14061205972; behavioral 14059004405; ET27 delete 14058874965; ET27 seal 14068064046. The 16 November revalidation checked GitHub artifact metadata; it did not re-download and recompute all ZIP digests.

This successor adds explicit tests for the authenticated SECURITY DEFINER wrapper contract and the server-only trusted-executor registry. All three workflows must run again on the successor's exact SHA. The prior green runs apply only to 318f561...

### 17.3 Security advisor disposition

The 19 November Supabase security advisor reported:
- private.aios_trusted_executors: RLS enabled, zero policies (INFO).
- public.aios_agent_trust_explain(uuid), public.aios_current_org_role(uuid), and public.aios_public_metrics(uuid): authenticated-callable SECURITY DEFINER warnings.
- Leaked-password protection disabled (WARN).

The first four findings have an intentional security design, now explicitly documented in docs/security/CLIENT-EXPOSED-RPC-BOUNDARY.md and covered by tests/sql/02_function_privilege_boundary.sql and tests/sql/15_trusted_executor_registry_boundary.sql:
- The three public RPCs are authenticated-only and enforce organization membership or caller-self membership; they are not anonymous endpoints.
- The trusted executor registry is server-only, has RLS enabled with zero policies, no direct PUBLIC/client/service grants, and is read through the private kernel SECURITY DEFINER authorization path.
- The CI SQL runner executes every tests/sql/*.sql file.

Leaked-password protection is an owner-controlled Auth setting and remains unchanged. Twenty-four unused-index performance notices are informational; no index was removed without workload evidence.

### 17.4 Hosted parity rechecked read-only

The 19 November read-only hosted inspection confirmed:
- aios_restorer is absent.
- Four audit protection triggers and two organization-validation triggers are all ORIGIN-enabled; none is ENABLE ALWAYS.
- service_role retains SELECT, INSERT, UPDATE, DELETE, REFERENCES, and TRIGGER on public.aios_audit_events; TRUNCATE is absent.
- Only the stale-task reaper and stale-approval expiry cron jobs are active. The hosted reaper still invokes the legacy direct function rather than the candidate serialized fail-closed scheduled wrapper.
- An authenticated owner-context audit verification has not been evidenced.

No production write, migration, grant/role/RLS/trigger/cron change, export, restore, or deployment was performed.

### 17.5 Release blockers and owner evidence

The following remain release blockers, not code changes Agent 004 can safely self-authorize:
1. Owner-level GitHub branch-protection/ruleset evidence, including CODEOWNERS enforcement, required reviews, bypass actors and administrator exemptions. The connected integration receives HTTP 403 for full branch-protection detail.
2. Owner-level Supabase backup/PITR and recovery evidence. Supabase Free has no managed scheduled backups; PITR requires paid capacity. No upgrade is authorized.
3. A separately approved, staged migration plan for the 12 unapplied migrations, including rollback/forward-recovery analysis and candidate-to-hosted catalog/function/grant parity.
4. Authenticated owner-context audit-chain verification.
5. Production export/isolated restore, secrets/Edge Function/cron reconstruction and application acceptance evidence.
6. Measured RPO/RTO and external TSA/RFC3161 trust-root lifecycle.

The release-evidence request remains open in [issue #38](https://github.com/Neuracoderepo1/AiOS/issues/38). Until its owner-controlled evidence is supplied and independently reviewed, keep PRs #34 and #35 draft/unmerged. No hosted migration, production write/export/restore, deployment, Auth/RLS/grant/trigger/cron change, billing change or paid upgrade is authorized by this checkpoint.

### 17.6 Stacked PR order

The implementation is stacked: PR #29 (main) → PR #31 → PR #34 → PR #35. Preserve this dependency chain. PR #35 must not be merged directly to main while omitting its parent work. Agent 004 implements; Agent 003 independently reviews. Production certification remains withheld.


## 19. Harness reporting and CI credential-redaction closure — 19 November 2026

The previous exact-head candidate 51916161800c718c3f3ab86a57678583cd54e088 completed all required workflows:
- AiOS CI run 44513144929: SUCCESS, all four jobs; post-lock approval-binding revalidation passed 10/10 independently reset and fully migrated PostgreSQL databases.
- ET27 delete-protection run 44513144856: SUCCESS; 66 checks passed, 10/10 mutation cases detected.
- ET27 seal-guard run 44513145150: SUCCESS; 303 checks passed, 48/48 mutation cases detected.

A subsequent inspection of the raw ET27 logs/artifacts found that local Supabase Storage access and secret keys were not covered by the existing startup-log redaction. Those runs used disposable local Supabase stacks and no production credentials or data; nevertheless, the logs/artifacts are marked TAINTED and are not accepted as clean release evidence. The successor adds redaction and leak assertions for Storage credentials, JWTs, Supabase API keys and database URLs in all three workflows. The main CI stack startup also uses the supported mailpit service name and bounded infrastructure-only retry. Fresh exact-head runs must generate clean replacement evidence.

The local Part D/E harness also had a collector defect: it did not parse PostgreSQL MXRES NOTICE records or explicit rollback-proof notices, and it misclassified successful static-check and golden-vector records. The successor parses MXRES and ROLLBACK_PROOF records into machine-readable result files, emits explicit rollback-proof markers for the Part D restoration savepoint and Part E non-UTC append fixture, corrects static/golden status parsing, and adds a parser self-test to CI and tests/harness/run_all.sh.

These are candidate-only changes until the new exact SHA passes all required workflows. The prior 5191616... green results do not certify the new successor. No hosted production changes were performed.


## 20. Agent 003 F-40-08/F-40-09 checkpoint — 22 November 2026

**PR #40:** [AiOS mission cancellation contract](https://github.com/Neuracoderepo1/AiOS/pull/40), OPEN / DRAFT / UNMERGED. It remains stacked on the PR #35 candidate branch; preserve the existing dependency order and do not merge this child independently.

**Previously reviewed exact baseline:** `d875f055d18d84efe5f678c0e5ff160e32b5bffb`. Agent 003 accepted F-40-04 through F-40-07 and the three exact-head workflows, but returned NOT CERTIFIED because F-40-08 and F-40-09 remained P1 blockers.

### Migration inventory and hosted boundary

The candidate tree contains **131 SQL migrations**. The last read-only hosted inventory contains **117 applied versions**, latest `20261108130000`, leaving **14 candidate migrations unapplied**. The two PR #40 additions are:

| Version | Candidate migration | Hosted state |
|---|---|---|
| `20261120180000` | `aios_mission_cancellation_jwt_identity.sql` | Unapplied |
| `20261120190000` | `aios_succeeded_mission_terminal_integrity.sql` | Unapplied |

This inventory is a candidate/hosted count comparison, not authorization to apply migrations. No hosted migration has been applied.

### Exact-head evidence for the reviewed d875 baseline

These results validate only `d875f055...`, not a later successor:

| Workflow | Run | Result |
|---|---:|---|
| AiOS CI | [44915756471](https://github.com/Neuracoderepo1/AiOS/actions/runs/44915756471) | SUCCESS, 4/4 jobs |
| ET27 seal guard | [44915756445](https://github.com/Neuracoderepo1/AiOS/actions/runs/44915756445) | SUCCESS, 303/303 checks, 48/48 mutants detected |
| ET27 delete protection | [44915756496](https://github.com/Neuracoderepo1/AiOS/actions/runs/44915756496) | SUCCESS, 66/66 checks, 10/10 mutants detected |

Agent 003 independently recomputed these artifact digests during its review:

| Evidence | Artifact ID | SHA-256 |
|---|---:|---|
| AiOS CI | 14711617965 | `1850c0da1b519d9e8f621ff251a3f840331357b85dcd8d260c1a9ca2c1fcd68e` |
| ET27 seal guard | 14711632635 | `b65748bf6fdf6d3ed077a4308e4b71b53ec91eff4685cc9d7528f1b30b15ad05` |
| ET27 delete protection | 14712026366 | `1a9047ff962bedd592c42b1eb6323986ea3febc8beb39dc35c94ef981fcf2358` |

The AiOS CI artifact records 131 migration files and passing tests 19/20. These historical results do not validate the F-40-08 successor.

### F-40-08 implementation successor

Agent 004 pushed candidate `335052a65540dd09639326e4467728a7fc181f79` to the existing PR #40 branch. It:

- Adds a database CHECK boundary so only the trusted `postgres`/`supabase_admin` database roles can create or modify a mission with status `succeeded`; authenticated, anon and service roles do not receive this exception.
- Adds a closed CHECK constraint for the recognized task-status set.
- Leaves the existing terminal-parent task gate and its lock behavior in place. Unknown statuses are rejected by the status constraint; known live statuses under a succeeded parent remain rejected by the existing gate.
- Adds `tests/sql/21_mission_succeeded_and_task_status_boundary.sql`, exercising authenticated JWT writes, trusted legacy seeding, unknown task statuses, live-task rejection under a succeeded parent, and positive controls.

At the time this checkpoint was authored, the three required workflows had been triggered on `335052a...` and were still running. Their results must not be inferred from the earlier d875 runs. This candidate is **implementation submitted / exact-head validation pending** until the new AiOS CI, ET27 seal and ET27 delete workflows all pass on one identical final SHA.

### Branch-governance evidence qualification

Earlier statements that main is protected are **owner-reported/historical**, not independently verified by this integration. The connected GitHub integration receives HTTP 403 from the detailed branch-protection endpoint; current ruleset inheritance, required-review/CODEOWNERS enforcement, bypass actors and administrator exemptions therefore remain unverified. Obtain current owner-level evidence before treating these controls as established.

### Release boundary

Production certification remains **WITHHELD / NOT CERTIFIED**. Keep PR #40 open, non-draft, and unmerged pending exact-head CI and Agent 003 re-review. No hosted migration, production write/export/restore, deployment, role/grant/RLS/trigger/cron/Auth change, secret change, billing change or production configuration change is authorized or performed. The 14 unapplied migrations remain unapplied. Scope is AiOS only.

## F-40-09 final documentation reconciliation — 22 November 2026

**Disposition: documentation reconciliation COMPLETE for the reviewed implementation candidate.** This records the verified evidence for candidate SHA `1a8156965c69fc47c01c5a05be378b9092150180`; it does not certify this documentation update or transfer the earlier candidate's evidence to a later commit.

F-40-08 implementation is present in reviewed candidate `1a8156965c69fc47c01c5a05be378b9092150180`. The three required workflows passed on that exact candidate:

| Workflow | Run | Exact-candidate result |
|---|---:|---|
| AiOS CI | [44981765290](https://github.com/Neuracoderepo1/AiOS/actions/runs/44981765290) | SUCCESS, 4/4 jobs |
| ET27 seal guard | [44981765301](https://github.com/Neuracoderepo1/AiOS/actions/runs/44981765301) | SUCCESS |
| ET27 delete protection | [44981765246](https://github.com/Neuracoderepo1/AiOS/actions/runs/44981765246) | SUCCESS |

The four corresponding GitHub-reported artifacts are:

| Workflow | Artifact name | Artifact ID | GitHub-reported SHA-256 |
|---|---|---:|---|
| AiOS CI | `aios-ci-evidence` | `14737864849` | `af510b2651c96edc0abc5965cfc99b097a18cbeb5d5aae343538dfd1d65faea1` |
| AiOS CI | `behavioral-evidence` | `14737614615` | `711d55dcc525ec1610cc378205dc03659e989eddc63b6496e103b41aba5ab244` |
| ET27 seal guard | `et27-seal-guard-evidence` | `14738047780` | `c93b4aa659c631ccf86b65ac9ca2e77f8bf64d1d514251d400816aff6fc77be2` |
| ET27 delete protection | `et27-delete-protection-evidence` | `14738420236` | `ba750e0fb39a60edda233236c508cb58c9172761253df12ba7b2a19ce7779b19` |

These run URLs, artifact names, IDs and digests identify evidence for `1a8156965c69fc47c01c5a05be378b9092150180` only. They are not evidence for this later documentation commit. Earlier checkpoint text describing the 335052a successor's workflows as pending is superseded by this verified exact-head result.

### Governance and production boundary

Agent 003's independent certification decision remains a separate governance gate. CI success and documentation reconciliation are not independent certification, production approval, migration readiness, or release approval. Do not describe AiOS as certified, production-approved, or release-closed unless and until Agent 003 issues the corresponding independent decision and all owner-controlled release gates are satisfied.

PR #40 must remain unmerged absent the required authorization. No deployment or hosted Supabase migration is authorized. No production data, roles, grants, RLS policies, triggers, cron jobs, Auth settings, secrets, billing, or configuration may be changed under this directive. No such production operation is authorized by these CI results.

**Access is not authority.** Agent 004 implements and supplies evidence; Agent 003 independently reviews and certifies. Any remaining certification findings must be documented and resolved through the established review process. Preserve all migration-readiness, recovery, owner-evidence, and release-approval qualifications elsewhere in this document.


## Final exact-head documentation/evidence reconciliation — 22 November 2026

**Recorded implementation/evidence SHA:** `dd72de937cbdd43b121bb75ec7b6ed393b1d4741`  
**PR #40 status:** OPEN / NON-DRAFT / UNMERGED. PR #40 is not a draft and must remain unmerged unless separately authorized.  
**Evidence binding:** GitHub run and artifact metadata associates the following records with exact head SHA `dd72de937cbdd43b121bb75ec7b6ed393b1d4741` on branch `agent004/mission-cancellation-contract`.

| Workflow | Run ID | Exact-head result |
|---|---:|---|
| AiOS CI | [44983255375](https://github.com/Neuracoderepo1/AiOS/actions/runs/44983255375) | SUCCESS, 4/4 jobs |
| ET27 seal guard | [44983255370](https://github.com/Neuracoderepo1/AiOS/actions/runs/44983255370) | SUCCESS |
| ET27 delete protection | [44983255372](https://github.com/Neuracoderepo1/AiOS/actions/runs/44983255372) | SUCCESS |

### Exact-head artifact inventory

| Workflow | Artifact | Artifact ID | GitHub-reported SHA-256 |
|---|---|---:|---|
| AiOS CI | `aios-ci-evidence` | `14739366654` | `5a276bbb0bac635b72664d5e599cb0c3943f6a6efafde0f2002bcdcac9f113ef` |
| AiOS CI | `behavioral-evidence` | `14738776890` | `6373b3760a8e98e9ebcf8aa2b280be6fc32f0e13f8c787f25d73f1e429f079d1` |
| ET27 seal guard | `et27-seal-guard-evidence` | `14739001350` | `6285ff446346a9bbb10b602db79b0e16bf5d999bbc458203d619566d06e6ce8c` |
| ET27 delete protection | `et27-delete-protection-evidence` | `14738297817` | `57caa2e27db83751642504439bf54d9efaad257951dd5ea30c65144a33e69405` |

The AiOS CI run completed all four jobs successfully: functions-behavioral, functions-typecheck, evidence-integrity, and migrations-and-sql-tests. The migrations/SQL job includes the canonical 46-case matrix, mission/task and approval-path race coverage, audit-lock interleavings, and approval-chain post-lock binding revalidation across ten fresh migrated databases. Both ET27 jobs completed migration replay, credential-redaction checks, their target suites, evidence upload, and cleanup successfully.

Digests above are GitHub-reported artifact digests bound to these workflow runs. They are not represented as independently recomputed local ZIP hashes.

### Migration inventory: preserved historical observation

The PR #40 candidate inventory recorded **14 candidate migrations unapplied** against a read-only hosted baseline of **117 applied migration versions**, with latest recorded version `20261108130000`. This is a historical candidate-versus-hosted observation, not a claim that hosted migration history was freshly queried during this documentation update. The 14 migrations remain unapplied. No migration is authorized or applied by this record.

### PR status correction and release boundary

Any earlier statement in this document that PR #40 was draft is stale and superseded: its verified status is **OPEN / NON-DRAFT / UNMERGED**. This correction does not authorize merging.

CI success and documentation reconciliation do not constitute Agent 003 certification, production approval, migration readiness, or deployment authorization. Production certification remains **WITHHELD / NOT CERTIFIED** unless and until Agent 003 issues a separate evidence-backed decision and all owner-controlled release gates are satisfied.

No hosted Supabase migration, production data write/export/restore, deployment, Edge Function release, role/grant/RLS/policy/trigger/cron/Auth change, secret change, billing change, plan upgrade, or production configuration change is authorized or performed by this documentation update. Preserve all existing recovery, owner-evidence, migration-parity, branch-governance, and release-approval qualifications. **Access is not authority.** Agent 004 implements and supplies evidence; Agent 003 independently reviews and certifies.


## 21. F-40-09 authoritative checkpoint — 22 November 2026

**Disposition:** documentation reconciliation submitted for independent review; not self-certified. This section supersedes, for current-state facts, every earlier PR #40 section in this document (including the section that labels `dd72de937cbdd43b121bb75ec7b6ed393b1d4741` as the implementation/evidence SHA), the 2026-11-19 banner at the top of this document, and the PR #35-era sections 17.1 and 17.2 (129/117/12, candidate `318f561...`). Earlier sections are preserved as historical evidence.

**Evidence SHA:** `03495472bf7ec40a2ca4e4fec8e63fb42a34224e`, the head of `agent004/mission-cancellation-contract` when this checkpoint was verified (before the commit that adds this section).  
**PR #40:** OPEN / NON-DRAFT / UNMERGED, base `agent004/f2-reaper-record-isolation`. It is a stacked child of PR #35: preserve the stack order and do not merge it independently.

### 21.1 Commit roles on the PR #40 branch

| SHA | Role |
|---|---|
| `d875f055` | Baseline reviewed by Agent 003: F-40-04 to F-40-07 accepted; F-40-08 and F-40-09 raised as P1 blockers |
| `335052a6` | F-40-08 implementation: modifies the unapplied migration `20261120190000` and adds `tests/sql/21_mission_succeeded_and_task_status_boundary.sql` |
| `1a815696`, `dd72de93`, `8af9935`, `6d6a8aa` | Documentation-only commits from earlier F-40-09 attempts |
| `5dd75fd` to `03495472` | Six CI commits touching three workflow files only (13 lines changed); no application, migration or test file |

Between `335052a6` and `03495472` the migration `20261120190000` and test 21 are byte-identical (same git blob IDs), so the F-40-08 implementation validated below is the one introduced at `335052a6`.

### 21.2 Exact-head workflow evidence for `03495472`

| Workflow | Run | Result |
|---|---:|---|
| AiOS CI | [44986420260](https://github.com/Neuracoderepo1/AiOS/actions/runs/44986420260) | SUCCESS, 4/4 jobs: evidence-integrity 6/6 steps, functions-behavioral 13/13, functions-typecheck 8/8, migrations-and-sql-tests 33/33 |
| ET27 seal guard | [44986420277](https://github.com/Neuracoderepo1/AiOS/actions/runs/44986420277) | SUCCESS, 1/1 job (11/11 steps) |
| ET27 delete protection | [44986420266](https://github.com/Neuracoderepo1/AiOS/actions/runs/44986420266) | SUCCESS, 1/1 job (11/11 steps) |

All three runs are `pull_request` events, attempt 1, with `head_sha` equal to the evidence SHA. They are the only workflow runs that exist for this SHA. Run, job and step results were read from the GitHub Actions API on 22 November 2026.

| Workflow | Artifact | Artifact ID | GitHub-reported SHA-256 |
|---|---|---:|---|
| AiOS CI | `aios-ci-evidence` | `14739837907` | `63a1718a682407aed20ea5020105222c22a94b2a6075dcdeeae1f3997b093f43` |
| AiOS CI | `behavioral-evidence` | `14740032238` | `e61883cdba00176e90653538f1b6467c0a8aecd6068a3d189fa2db024897b81d` |
| ET27 seal guard | `et27-seal-guard-evidence` | `14739558832` | `436a01b532406eafc07dc16212a55042857c57650cace654c12fe33ec42b5da7` |
| ET27 delete protection | `et27-delete-protection-evidence` | `14739997312` | `d59422318030ad1103c033842a1ddc4969c3be1515bf1d1154746382f9d53553` |

All four artifacts were unexpired and bound to the evidence SHA by GitHub metadata. The digests are GitHub-reported; the artifact ZIPs were not downloaded or re-hashed in this verification because the artifact download host was not reachable from the verification environment. Agent 003's independent recomputation recorded earlier applies to the `d875f055` artifacts only. Per-suite check and mutant counts recorded for `d875f055` are not restated for this SHA.

The migrations-and-sql-tests job completed these steps successfully: full migration replay from scratch, real-PostgreSQL logical export and isolated restore, the SQL regression and invariant runner (every `tests/sql/*.sql` file, including test 21), the canonical 46-case matrix, mission/task authority races, approval-path and reverse-link lock-order suites, audit-lock forced interleavings, the smoke self-test, and approval-chain binding revalidation across 10 fresh migrated databases.

### 21.3 Migration inventory and hosted boundary

The candidate tree at the evidence SHA contains **131 SQL migration files**. The last read-only hosted observation (19 November, section 17.1; not re-queried for this checkpoint) is **117 applied versions**, latest `20261108130000`. The candidate is therefore **14 migrations ahead**: the 12 listed in section 17.1, plus

| Version | Candidate migration | Hosted state |
|---|---|---|
| `20261120180000` | `aios_mission_cancellation_jwt_identity.sql` | Unapplied |
| `20261120190000` | `aios_succeeded_mission_terminal_integrity.sql` | Unapplied |

`20261120190000` was modified by `335052a6` before any application; it has never been applied anywhere hosted. This inventory is a count comparison, not authorization to apply migrations. No hosted migration has been applied.

### 21.4 Finding dispositions at this checkpoint

- **F-40-04 to F-40-07:** accepted by Agent 003 at `d875f055` (22 November review).
- **F-40-08:** implementation present from `335052a6`, exercised by SQL test 21 inside the green SQL regression runner at the evidence SHA. Independent disposition **pending Agent 003**; this document does not close it.
- **F-40-09:** this section is the reconciliation. Independent disposition **pending Agent 003**.
- Production certification remains **WITHHELD / NOT CERTIFIED**.

### 21.5 Statements superseded by this checkpoint

- PR #40 described as DRAFT (section 20): its status is OPEN / NON-DRAFT / UNMERGED.
- 129/117/12 and `318f561...` as the current candidate (top banner, sections 17.1 and 17.2): current inventory is 131/117/14 and the PR #40 evidence SHA is `03495472...`.
- F-40-08 validation described as pending (section 20): see 21.2 and 21.4.
- `dd72de93` labelled as the implementation/evidence SHA: it is a documentation-only commit; the implementation is `335052a6` and the evidence of record is `03495472`.
- Section 4 and section 17.5 branch-protection wording: see 21.6.

### 21.6 Branch-protection observation (supersedes the HTTP 403 qualification for the fields listed)

On 22 November 2026, read-only GitHub API calls with this session's credentials returned `main` as protected and returned the branch-protection detail (sections 4 and 17.5 recorded HTTP 403 for the previously connected integration). Observed: required status checks `evidence-integrity`, `functions-typecheck`, `migrations-and-sql-tests` with up-to-date branches required; **required approving reviews: 0**; stale-review dismissal on; code-owner review **not** required; last-push approval not required; administrators **not** enforced; force pushes and deletions disallowed; conversation resolution required; signed commits and linear history not required; repository-level rulesets: empty list.

Earlier statements that `main` is protected should therefore be read as "required status checks, with no required human review and no administrator enforcement". Organization-level rulesets and bypass actors are not established by this observation; owner-level evidence is still required for them. No branch-protection setting was altered.

### 21.7 Release boundary

CI success and this reconciliation are not Agent 003 certification, production approval, migration readiness or deployment authorization. No hosted Supabase migration, production data write/export/restore, deployment, Edge Function release, role/grant/RLS/policy/trigger/cron/Auth change, secret change, billing change, plan upgrade or production configuration change is authorized or was performed. The 14 unapplied migrations remain unapplied. Scope is AiOS only. **Access is not authority.**

### 21.8 Documentation successor rule

A file cannot hold evidence for the commit that contains it. The commit that adds this section receives its own AiOS CI, ET27 seal guard and ET27 delete protection runs; their IDs, conclusions and artifact digests are reported in the PR #40 submission comment for that exact SHA. The results in 21.2 do not transfer to it.


## 22. Agent 003 disposition on `f1e4597e` — 22 November 2026

Source: Agent 003 independent review of PR #40, [review 6012890834](https://github.com/Neuracoderepo1/AiOS/pull/40#pullrequestreview-6012890834), submitted 2026-11-22T14:54:39Z against commit `f1e4597e55b7f8338608029d4abd9392ca47d3e1`. This section supersedes the "pending Agent 003" wording in 21.4 and 21.7; sections 21.1 to 21.3 and 21.5 to 21.6 stand.

### 22.1 Dispositions

- **F-40-09: CLOSED** at documentation-reconciliation level.
- **F-40-08: ACCEPTED** at source and real-PostgreSQL test-evidence level. This acceptance does not authorize applying the migration to hosted Supabase.
- **Production certification: WITHHELD / NOT CERTIFIED.** This is not merge authorization.

### 22.2 Exact-head evidence for `f1e4597e`

| Workflow | Run | Result |
|---|---:|---|
| AiOS CI | [45033163765](https://github.com/Neuracoderepo1/AiOS/actions/runs/45033163765) | SUCCESS, 4/4 jobs |
| ET27 seal guard | [45033163829](https://github.com/Neuracoderepo1/AiOS/actions/runs/45033163829) | SUCCESS, 1/1 job |
| ET27 delete protection | [45033163866](https://github.com/Neuracoderepo1/AiOS/actions/runs/45033163866) | SUCCESS, 1/1 job |

| Artifact | Artifact ID | SHA-256 (matches GitHub metadata) |
|---|---:|---|
| `aios-ci-evidence` | `14758987200` | `4c3b055418a758e8d2d62c6d829d22b977701ee904d5f20117dcf1a424832fd8` |
| `behavioral-evidence` | `14758802020` | `1422707481bcde1d86aa39ab38652c01a2f8971fe4c42ac44a6f19eb6c560881` |
| `et27-seal-guard-evidence` | `14758533227` | `efe5b61dadcb1a8d756edb4f9f458b8cedf542effa8cbcacfec773210eeaeb23` |
| `et27-delete-protection-evidence` | `14758836974` | `ebdf82eedba198248a21465195071dd264f741b7130911bda88ee911ebb1cf3e` |

Agent 003 downloaded these four archives and recomputed SHA-256 over the ZIP bytes; each matched GitHub's artifact metadata. This independent recomputation covers the `f1e4597e` artifacts only, not the `03495472` artifacts recorded in 21.2. Agent 003 also confirmed that the AiOS evidence archive shows 131 migrations applied by the SQL runner and `tests/sql/21_mission_succeeded_and_task_status_boundary.sql` passing.

### 22.3 Branch governance and remaining release gates

Agent 003's GitHub connection still receives HTTP 403 from the branch-protection endpoint, so it did **not** certify the branch-protection values in 21.6. Those values remain a single-session observation, and the owner-level evidence qualification in sections 4 and 17.5 stands.

The following remain separate release gates (section 17.5) and are unchanged by this section: fresh hosted schema/function/grant parity (the 117 hosted-applied count is still the 19 November observation); a separately approved staged plan for the 14 unapplied migrations; authenticated owner-session audit verification; managed backup and recovery evidence; complete owner-level branch-governance evidence.

### 22.4 Boundary and successor rule

The closure above was granted on `f1e4597e55b7f8338608029d4abd9392ca47d3e1`. The commit that adds this section is a documentation-only successor with its own workflow runs, reported in the PR #40 comment for that exact SHA; Agent 003's review does not cover it. No hosted migration, deployment, merge, production data change, privilege/security/configuration change, secret change or billing change is authorized or was performed by this record. **Access is not authority.**

## 23. F-40-10 authenticated owner audit verification implementation — 22 November 2026

Agent 004 added a tenant-scoped authenticated owner verification path in Part E of `20261109130000_aios_audit_anchoring_part_e.sql` and regression test `tests/sql/22_authenticated_owner_audit_verification.sql`.

- `public.aios_audit_verify_owner(uuid)` derives identity from `auth.uid()`, locks the caller's membership row `FOR SHARE`, and requires owner/admin/administrator membership for the requested organization.
- The response is tenant-scoped; it does not expose the global organization inventory or other organizations' event details.
- Successful calls create append-only verification history with `kind = 'owner'` and the authenticated `actor_user_id`.
- Only `authenticated` receives EXECUTE on the public wrapper. `anon`, `service_role`, PUBLIC and authenticated direct access to the private implementation/global verifier are denied.
- The result remains explicitly non-certification-grade (`service_role_asserted`, `certification_grade = false`).

The first exact-head CI attempt identified a D01.2 namespace collision with the existing single-global-verifier invariant. The private function was renamed to `private.aios_owner_audit_verify(uuid)`, preserving the guard and all existing verifier pins.

SQL test 22 covers actor binding, owner/member authorization, cross-organization denial, grants, response scope and append-only actor attribution in disposable CI PostgreSQL. This is regression evidence only; it does not replace genuine hosted owner-session verification.

### 23.1 Evidence identity and workflow status

The implementation and documentation changes are in PR #40 on `agent004/mission-cancellation-contract`. The latest documentation successor receives its own AiOS CI, ET27 seal guard and ET27 delete protection runs. Earlier candidate workflow results are not transferable to this exact head. The latest exact-head workflow URLs and outcomes are recorded in the PR handoff after completion.

### 23.2 Production release determination

F-40-10's code-level owner-verification gap is addressed in the candidate, pending exact-head CI and independent Agent 003 review. Production owner-session proof remains outstanding. External attestation/trust-root validation, fresh hosted schema/function/grant parity, approved staged migration execution, managed backup/recovery evidence, and owner-level branch-governance evidence remain separate release gates.

No hosted migration, deployment, merge, production data write, role/grant/RLS/trigger/cron/Auth change, export/restore, secret change or billing change was performed or authorized. PR #40 remains open and unmerged. **Access is not authority.**


## 24. AiOS final hosted observation and staged release gates — 22 November 2026

**Evidence-bearing candidate:** `58a67702efa2167c2060bb3e40d37880b7b6b00d` on `agent004/mission-cancellation-contract`; [PR #40](https://github.com/Neuracoderepo1/AiOS/pull/40), OPEN / NON-DRAFT / UNMERGED.  
**Decision:** engineering evidence accepted for F-40-08 and F-40-10 at candidate source/CI level; F-40-09 closed at the previously reviewed documentation checkpoint. **Production certification remains WITHHELD / NOT CERTIFIED.**

### 24.1 Exact-head workflow results

All required workflows passed on the identical exact SHA `58a67702efa2167c2060bb3e40d37880b7b6b00d`:

| Workflow | Run | Result |
|---|---:|---|
| AiOS CI | [45049001169](https://github.com/Neuracoderepo1/AiOS/actions/runs/45049001169) | SUCCESS, 4/4 jobs |
| ET27 seal guard | [45049001172](https://github.com/Neuracoderepo1/AiOS/actions/runs/45049001172) | SUCCESS, 303/303 checks; 48/48 mutants detected |
| ET27 delete protection | [45049001252](https://github.com/Neuracoderepo1/AiOS/actions/runs/45049001252) | SUCCESS, 66/66 checks; 10/10 mutants detected |

The AiOS CI job set passed: evidence integrity, behavioral suite, Edge Function typecheck, and migrations/SQL tests. The latter passed the 131-migration replay, real-PostgreSQL export/isolated restore, SQL tests 21 and 22, 46-case canonical matrix, mission/task and approval concurrency, audit-lock interleavings, 86/86 smoke self-test, and 10/10 fresh-database approval-chain binding revalidations. The Part E log records E02.8/E02.8a passing. SQL test 22 passed in disposable CI PostgreSQL; it does not constitute a real hosted owner session.

### 24.2 Artifact identity

The following unexpired artifacts are bound by GitHub workflow metadata to the exact SHA above. Digests are GitHub-reported and were not independently recomputed in this checkpoint.

| Workflow | Artifact | ID | SHA-256 |
|---|---|---:|---|
| AiOS CI | `aios-ci-evidence` | 14764379287 | `591052b40ecb1fb3b9b7aebe714035a6bbf4a6f93eca78c84772b06f651b2f20` |
| AiOS CI | `behavioral-evidence` | 14765021178 | `81dcbba7f7c4566dddd65e48b177a2cdba96ca9c3138f04de9963a0860b2fa72` |
| ET27 seal guard | `et27-seal-guard-evidence` | 14764946686 | `4975a6c92cbf91c206252bf526104c3d2bbadce084ce6a6d5d3485a89629fe90` |
| ET27 delete protection | `et27-delete-protection-evidence` | 14765006490 | `92814ecfeff486bc78e0d4a59e4ed4e8cbc954878aa8dbc9dfbf1067d4d6b882` |

### 24.3 Fresh hosted read-only observation — approximately 19:58 UTC

Project `jtkcdwhiduixoiodhbfn`: 117 applied migration versions, latest `20261108130000`; candidate tree 131 migrations, leaving 14 unapplied. RLS is enabled on all 17 public base tables and the one private base table. The two existing five-minute cron jobs, `aios-reap-stale-tasks` and `aios-expire-stale-approvals`, are active.

Security advisor observations: three previously tracked authenticated SECURITY DEFINER warnings; leaked-password protection disabled as a budget deferral; and an informational no-policy RLS finding on `private.aios_trusted_executors`, intentionally deny-by-default. Sixteen client-executable functions were inventoried. All SECURITY DEFINER functions have empty pinned search paths; confirm the intended exposure of invoker `public.aios_risk_rank` to anon with `search_path=public` and `public.verify_audit_chain` to authenticated.

The 14 unapplied versions, in order: `20261108140000`, `20261108150000`, `20261109120000`, `20261109130000`, `20261110100000`, `20261111170000`, `20261111190000`, `20261111200000`, `20261111210000`, `20261111220000`, `20261111230000`, `20261113160000`, `20261120180000`, `20261120190000`.

At observation time, succeeded missions with live tasks/invocations/approvals were 0/0/0; succeeded missions overall 0; tasks outside the allowed status set 0; running tasks 0. In-flight work was 10 queued tasks, 3 queued missions, 1 pending approval, 4 requested invocations and 2 requires-approval invocations. These are point-in-time facts and must be rechecked immediately before a migration window.

A clean-replay comparison of hosted schema, function definitions and grants has not yet been completed. It is scheduled after authorized migration execution. This observation does not establish hosted catalog parity.

### 24.4 Material migration delta

Migration `20261109130000_aios_audit_anchoring_part_e.sql` gained 245 lines after the prior evidence checkpoint `03495472bf7ec40a2ca4e4fec8e63fb42a34224e`. The current 58a677 exact-head CI replay and Part E SQL tests pass. The evidence for the added content is the exact-head workflow set and artifacts in 24.1–24.2; older workflow evidence must not be substituted.

### 24.5 Owner decisions

1. **External attestation:** retain `EXTERNAL_DEPENDENCY_BLOCKED` as documented residual risk for this candidate. Release language may claim internal verification only. Do not claim external or certification-grade attestation until an RFC 3161/TSA trust root is selected and exercised.
2. **Backup/recovery:** re-scope to budget-neutral evidence. Supabase Free has no managed backups or PITR; no paid upgrade is authorized. Before migration, take a schema-and-data logical dump, restore it into a disposable local stack, compare against freshly captured content fingerprints, and record measured RTO. This exercise is not yet complete. Only after successful exercise may release language say: **“No managed backup or PITR; logical-dump recovery exercised once.”** PITR purchase trigger: first paying customer or any non-demo tenant data.
3. **Staged migrations:** approve the version-ordered 14-migration plan as a plan only; execution remains held. The intended path is merge through the existing Supabase deploy pipeline to preserve migration version parity. No MCP or SQL-editor application.

### 24.6 Gates

| Gate | Required action | Authority |
|---|---|---|
| G1 | Freeze head; all three workflows pass on one exact SHA with clean artifacts | Agent |
| G2 | Written independent disposition on that exact SHA | Agent 003 |
| G3 | Pre-migration logical dump and isolated restore, fingerprint comparison and measured RTO | Human Director controls |
| G4 | Immediately-before-window check: zero running tasks; record queued work and pending approval | Agent |
| G5 | Merge PR #40 through the approved deploy pipeline, applying the 14 migrations | Human Director only |
| G6 | Post-deploy migration count/head, clean-replay catalog diff, cron/advisor/fingerprint checks, 46-case matrix and smoke | Agent |
| G7 | Real owner sign-in and F-40-10 procedure; record actual actor ID, org ID, JWT subject and result | Human Director only |

G1 has passed on 58a677. Agent 003 reviewed that exact candidate and accepted the engineering evidence, while identifying the stale documentation status now corrected by this checkpoint. The documentation successor must receive its own three exact-head workflows and Agent 003 re-review. G3, the immediate G4 check, G5, G6 and G7 remain outstanding. G2 must be refreshed for the final documentation successor.

### 24.7 Remaining owner evidence and production boundary

The Human Director must supply current branch-protection and organization-ruleset evidence, including required reviews, bypass actors and administrator enforcement. Earlier API observations are not a substitute for complete owner-level evidence.

There are no down-migrations. Recovery is forward-fix or restoration from the G3 dump. Stop on any error and do not proceed to the next migration. No production dump, restore, migration or write has been performed in this checkpoint.

PR #40 remains OPEN / NON-DRAFT / UNMERGED. Production certification remains **WITHHELD / NOT CERTIFIED**. No merge, deployment, hosted migration, production data write/export/restore, role/grant/RLS/policy/trigger/cron/Auth change, secret change, billing change, paid upgrade or production configuration change is authorized or performed. **Access is not authority.** Agent 004 implements and supplies evidence; Agent 003 independently reviews and certifies.
