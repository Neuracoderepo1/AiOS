# AiOS current state and release boundary

**Snapshot:** 2026-11-19 11:06 UTC  
**Implementation candidate before this successor:** 318f561a475a23e731e8d4e8d55ffb1d9d49075c  
**Candidate branch:** agent004/f2-reaper-record-isolation (PR #35; this commit adds security-boundary regression coverage and reconciles the release record)  
**Default branch HEAD:** 377e641c77245d4b093e82b6597c5efd55f764d9  
**Hosted project:** jtkcdwhiduixoiodhbfn, Project AiOS, PostgreSQL 17.6, Supabase Free  
**Release status:** PRODUCTION CERTIFICATION WITHHELD / NOT CERTIFIED

## Engineering candidate and independent review

PR #35 is open, draft, and unmerged. It is a stacked candidate, not a standalone branch: PR #29 (base main) → PR #31 → PR #34 → PR #35. Preserve this dependency order when preparing any merge. Do not merge a child branch directly to main while omitting its parent changes.

Agent 003 independently reviewed exact candidate 318f561a475a23e731e8d4e8d55ffb1d9d49075c on 16 November 2026. The F-2 per-record stale-task reaper behavior and associated engineering evidence were accepted. This is implementation acceptance only; Agent 003 explicitly withheld production certification and directed that PR #35 remain draft and unmerged.

## Exact-head engineering evidence for implementation baseline

All three required workflows passed on exact SHA 318f561a475a23e731e8d4e8d55ffb1d9d49075c:

| Workflow | Run | Result |
|---|---:|---|
| AiOS CI | [43468907258](https://github.com/Neuracoderepo1/AiOS/actions/runs/43468907258) | SUCCESS, 4/4 jobs |
| ET27 delete protection | [43468907181](https://github.com/Neuracoderepo1/AiOS/actions/runs/43468907181) | SUCCESS |
| ET27 seal guard | [43468907207](https://github.com/Neuracoderepo1/AiOS/actions/runs/43468907207) | SUCCESS, retry attempt 2 |

Agent 003 rechecked the exact-head run/job/artifact metadata on 16 November. The recorded artifacts are AiOS CI 14061205972, behavioral 14059004405, ET27 delete 14058874965, and ET27 seal 14068064046. The seal guard's successful result is retry attempt 2. These runs validate SHA 318f561... only. The security-test/documentation successor created by this update requires fresh exact-head workflows; no earlier run is substituted for it.

## Migration parity

A fresh candidate-tree inventory contains **129 SQL migration files**. The hosted migration history contains **117 applied versions**, latest 20261108130000. The candidate is therefore **12 migrations ahead** of hosted history.

| Version | Candidate migration | Hosted state |
|---|---|---|
| 20261108140000 | execution lock order and task terminal cascade | Unapplied |
| 20261108150000 | approval paths global lock order | Unapplied |
| 20261109120000 | restoration Part D | Unapplied |
| 20261109130000 | audit anchoring Part E | Unapplied |
| 20261110100000 | batch prelock before audit | Unapplied |
| 20261111170000 | shared approval/invocation resolver | Unapplied |
| 20261111190000 | restorer allowlist and mission reconciliation | Unapplied |
| 20261111200000 | mission reconciliation schedule registry | Unapplied |
| 20261111210000 | mission reconciliation trigger | Unapplied |
| 20261111220000 | approval binding and audit lock order | Unapplied |
| 20261111230000 | stale-task reaper per-record isolation | Unapplied |
| 20261113160000 | stale-task reaper fail-closed hardening | Unapplied |

The candidate passes clean-room migration replay in CI. This does not prove hosted catalog parity or authorize applying these 12 migrations. No hosted migration has been applied as part of this work.

## Hosted production observations (read-only)

The Supabase project is ACTIVE_HEALTHY. Read-only SQL on 19 November confirmed:

- aios_restorer is absent.
- Six non-internal triggers exist on public.aios_audit_events: four audit-protection triggers and two organization-validation triggers. All six are ORIGIN-enabled; none are ENABLE ALWAYS.
- service_role retains SELECT, INSERT, UPDATE, DELETE, REFERENCES, and TRIGGER on public.aios_audit_events; TRUNCATE is not granted.
- Only two active AiOS cron jobs are present: stale-task reaper and stale-approval expiry, each scheduled every five minutes. The deployed reaper command still calls private.aios_reap_stale_tasks('10 minutes'::interval) directly rather than the candidate's serialized fail-closed scheduled wrapper.
- The authenticated owner-context audit verifier has not been evidenced through the connected SQL session.

These are material candidate-to-hosted differences. They are not permission to normalize hosted state with ad-hoc SQL.

## Supabase advisor triage (19 November)

The live security advisor reports:

| Finding | Level | Disposition |
|---|---|---|
| private.aios_trusted_executors has RLS but no policies | INFO | Intentional server-only, deny-by-default table; explicit regression coverage and rationale added in this successor |
| Three authenticated-callable SECURITY DEFINER RPCs | WARN | Intentional authenticated wrappers with membership/self-role checks; explicit ACL, search-path and anonymous-denial regression coverage added in this successor |
| Leaked-password protection disabled | WARN | Owner-controlled Auth configuration; not changed by SQL or this PR |

The three wrappers are public.aios_agent_trust_explain(uuid), public.aios_current_org_role(uuid), and public.aios_public_metrics(uuid). Their intended security boundary is documented in docs/security/CLIENT-EXPOSED-RPC-BOUNDARY.md. The 24 unused-index performance notices are informational candidates only; no index is removed without workload and query-plan evidence.

## Recovery, audit and governance blockers

- Supabase Free does not provide managed scheduled backups; PITR requires a paid plan/add-on. No paid upgrade is authorized.
- No managed backup timestamp, production export, production-copy restore, measured RPO/RTO, or full recovery exercise is evidenced.
- GitHub reports main protected with required checks evidence-integrity, functions-typecheck, and migrations-and-sql-tests. The detailed branch-protection endpoint returns HTTP 403 to the connected integration; inherited organization rulesets, CODEOWNERS enforcement, stale-review dismissal, bypass actors, and administrator exemptions remain not fully verified.
- Full candidate-to-hosted function-definition/hash parity, function grant-intent reconciliation, hosted cron/reconciliation parity, and authenticated owner-context audit verification remain open.
- External TSA/RFC3161 trust-root lifecycle and measured RPO/RTO remain unproven.
- Owner evidence requested in issue #38 remains outstanding.

## Release boundary

Keep PRs #34 and #35 draft and unmerged until the stacked candidate is independently reviewed and owner-controlled release evidence is supplied. Do not apply the 12 unapplied migrations, alter hosted grants/RLS/Auth/roles/triggers/cron, export or restore production data, deploy Edge Functions, change billing, or upgrade the plan without a separate explicit owner-approved release operation and a reviewed migration/recovery plan.

Agent 004 implements and supplies evidence. Agent 003 independently reviews. Agent 004 does not self-certify production readiness. Scope is AiOS only; Armadillon and Arbitron are excluded.


## Engineering follow-up: harness evidence and CI credential safety

The candidate successor after 19 November adds two further engineering closures:
- The Part D/E result collector now parses the actual PostgreSQL MXRES NOTICE format and explicit ROLLBACK_PROOF notices. It no longer misclassifies successful static-check and golden-vector output. A parser self-test runs in CI and the local run_all harness.
- All three local Supabase workflows redact and check API keys, JWTs, database URLs, and generated Storage access/secret keys before logs or artifacts are retained. The main CI stack startup uses mailpit, bounded startup retries, and port/container diagnostics.

The preceding exact-head runs on 51916161800c718c3f3ab86a57678583cd54e088 completed successfully: AiOS CI 44513144929 (4/4 jobs, including 10/10 fresh-database binding revalidations), ET27 delete protection 44513144856 (66 checks, 10/10 mutants detected), and ET27 seal guard 44513145150 (303 checks, 48/48 mutants detected). Their evidence artifacts were generated before the Storage credential redaction correction and must be treated as tainted, not as clean release evidence. The credentials were generated by disposable local Supabase stacks; there is no evidence of production credentials or production data exposure. The new successor requires fresh exact-head CI and clean replacement artifacts.

This does not change the production boundary: 12 migrations remain unapplied to the hosted project, and production certification remains withheld.


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

Production certification remains **WITHHELD / NOT CERTIFIED**. Keep PR #40 draft and unmerged pending exact-head CI and Agent 003 re-review. No hosted migration, production write/export/restore, deployment, role/grant/RLS/trigger/cron/Auth change, secret change, billing change or production configuration change is authorized or performed. The 14 unapplied migrations remain unapplied. Scope is AiOS only.

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
