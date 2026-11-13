# AiOS budget-neutral release closure checkpoint

**Inspection date:** 2026-11-13  
**Candidate at start of inspection:** `13394941bc31a8005777ee40cf0ce87115e6783a`  
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

The exporter requires an explicit `NONPRODUCTION` marker restricted to loopback, or an `OWNER_APPROVED_NONPRODUCTION:<approval-id>` / `OWNER_APPROVED_PRODUCTION:<approval-id>` marker for remote sources. It rejects remote `PGHOSTADDR` and libpq service overrides for loopback non-production exports, reads secrets only through libpq's protected `PGPASSFILE`, and refuses output inside the repository. The production marker is a guardrail, not a substitute for owner approval. No production export was performed. The restore script accepts only loopback targets and a database name prefixed `aios_restore_`, validates checksums, refuses non-empty targets, and runs `pg_restore` in a single transaction.

**Verification boundary:** The fail-closed self-test is wired into CI, but no successful real-PostgreSQL export/restore cycle has yet been evidenced. The validator is structural only; it does not by itself prove audit-chain integrity, owner-context authorization, cron reconstruction, application behavior, or measured recovery objectives. Therefore logical recovery is **PARTIALLY IMPLEMENTED / ENGINEERING VERIFICATION PENDING**, not CLOSED.

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

The documentation and recovery-toolkit commits supersede the earlier candidate SHA. The implementation candidate `16c65b8d5bb730d8813124c39a6276df53ea721c` passed all three exact-head workflows: AiOS CI 43346710190, ET27 delete protection 43346709899, and ET27 seal guard 43346710291. The documentation update in this commit is a separate docs-only candidate and must receive fresh CI before being treated as the current PR head.

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


## 14. Final implementation-candidate CI and artifact evidence

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
