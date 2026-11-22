# AiOS current state and release boundary

**Snapshot:** 2026-11-19 11:06 UTC  
**Implementation candidate before this successor:** 318f561a475a23e731e8d4e8d55ffb1d9d49075c  
**Candidate branch:** agent004/f2-reaper-record-isolation (PR #35; this commit adds security-boundary regression coverage and reconciles the release record)  
**Default branch HEAD:** 377e641c77245d4b093e82b6597c5efd55f764d9  
**Hosted project:** jtkcdwhiduixoiodhbfn, Project AiOS, PostgreSQL 17.6, Supabase Free  
**Release status:** PRODUCTION CERTIFICATION WITHHELD / NOT CERTIFIED

> **Latest authoritative checkpoint (22 November 2026):** section *25. F-40-09 successor reconciliation and PR stack snapshot* supersedes earlier F-40-09 disposition wording for interpretation and records the current PR stack. Section 21 remains the historical evidence checkpoint at SHA `03495472bf7ec40a2ca4e4fec8e63fb42a34224e`; later exact-head evidence and Agent 003's documentation-level disposition are recorded in sections 22 and 24. Earlier text is preserved as historical evidence.

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

**Disposition:** documentation reconciliation submitted for independent review; not self-certified. This section supersedes, for current-state facts, every earlier PR #40 section in this document (including the section that labels `dd72de937cbdd43b121bb75ec7b6ed393b1d4741` as the implementation/evidence SHA) and the 2026-11-19 header figures (129/117/12, candidate `318f561...`). Earlier sections are preserved as historical evidence.

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

The candidate tree at the evidence SHA contains **131 SQL migration files**. The last read-only hosted observation (19 November, not re-queried for this checkpoint) is **117 applied versions**, latest `20261108130000`. The candidate is therefore **14 migrations ahead**: the 12 listed in the migration parity section above, plus

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
- 129/117/12 and `318f561...` as the current candidate: current inventory is 131/117/14 and the PR #40 evidence SHA is `03495472...`.
- F-40-08 validation described as pending (section 20): see 21.2 and 21.4.
- `dd72de93` labelled as the implementation/evidence SHA: it is a documentation-only commit; the implementation is `335052a6` and the evidence of record is `03495472`.

### 21.6 Branch-protection observation (supersedes the HTTP 403 qualification for the fields listed)

On 22 November 2026, read-only GitHub API calls with this session's credentials returned `main` as protected and returned the branch-protection detail (earlier checkpoints recorded HTTP 403 for the previously connected integration). Observed: required status checks `evidence-integrity`, `functions-typecheck`, `migrations-and-sql-tests` with up-to-date branches required; **required approving reviews: 0**; stale-review dismissal on; code-owner review **not** required; last-push approval not required; administrators **not** enforced; force pushes and deletions disallowed; conversation resolution required; signed commits and linear history not required; repository-level rulesets: empty list.

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

Agent 003's GitHub connection still receives HTTP 403 from the branch-protection endpoint, so it did **not** certify the branch-protection values in 21.6. Those values remain a single-session observation, and the owner-level evidence qualification stands.

The following remain separate release gates and are unchanged by this section: fresh hosted schema/function/grant parity (the 117 hosted-applied count is still the 19 November observation); a separately approved staged plan for the 14 unapplied migrations; authenticated owner-session audit verification; managed backup and recovery evidence; complete owner-level branch-governance evidence.

### 22.4 Boundary and successor rule

The closure above was granted on `f1e4597e55b7f8338608029d4abd9392ca47d3e1`. The commit that adds this section is a documentation-only successor with its own workflow runs, reported in the PR #40 comment for that exact SHA; Agent 003's review does not cover it. No hosted migration, deployment, merge, production data change, privilege/security/configuration change, secret change or billing change is authorized or was performed by this record. **Access is not authority.**

## 23. F-40-10 authenticated owner audit verification implementation — 22 November 2026

Agent 004 added a tenant-scoped authenticated owner verification path in Part E of `20261109130000_aios_audit_anchoring_part_e.sql` and regression test `tests/sql/22_authenticated_owner_audit_verification.sql`.

- Public RPC: `public.aios_audit_verify_owner(uuid)`; private implementation: `private.aios_owner_audit_verify(uuid)`.
- Caller identity is derived from `auth.uid()`. The caller's organization-membership row is locked `FOR SHARE` before the owner/admin role check.
- Only `owner`, `admin`, or `administrator` can verify the requested organization. The response contains only that organization's audit result and aggregate global-control booleans, not the global organization inventory.
- Each successful call writes an append-only verification-run row with `kind = 'owner'` and `actor_user_id` bound to the authenticated caller.
- The private implementation and global verifier remain unavailable to client/service roles. The public wrapper is executable by `authenticated` only; `anon` and `service_role` are denied.
- The RPC explicitly reports `external_attestation_trust = 'service_role_asserted'` and `certification_grade = false`. It is not an external attestation or production certification.

The initial CI attempt exposed the existing D01.2 canonical-verifier namespace guard: the first private function name was counted as a competing verifier. Agent 004 renamed it to `private.aios_owner_audit_verify(uuid)`; the guard is preserved, not weakened.

Regression test 22 exercises JWT-subject binding, owner/member authorization, cross-organization denial, RPC grants, response scope and actor-attributed verification history. Its JWT claim is set in disposable CI PostgreSQL and is **not** genuine hosted owner-session evidence.

### 23.1 Current exact-head validation

Candidate branch: `agent004/mission-cancellation-contract`. The current documentation successor has its own exact-head AiOS CI, ET27 seal-guard and ET27 delete-protection workflows pending. Results from earlier implementation commits do not transfer to this documentation successor. The PR remains open and unmerged.

### 23.2 Remaining production release gates

- Genuine authenticated owner-session verification using the actual owner account and its real JWT, with actor and organization evidence. Do not use service-role or simulated identity.
- Independent external attestation and trust-root validation. The current verifier deliberately remains non-certification-grade.
- Fresh hosted schema/function/grant parity and the separately authorized staged 14-migration execution plan.
- Genuine managed backup and tested recovery evidence.
- Owner-level organization ruleset and bypass-actor evidence.

No hosted migration, production data write, grant/role/RLS/trigger/cron/Auth change, deployment, merge, backup/restore, secret change or billing change was performed. PR #40 remains open and unmerged. **Access is not authority.**


## 24. Final hosted observation and owner-controlled release gates — 22 November 2026

**Evidence-bearing candidate SHA:** `58a67702efa2167c2060bb3e40d37880b7b6b00d`  
**Branch / PR:** `agent004/mission-cancellation-contract`, [PR #40](https://github.com/Neuracoderepo1/AiOS/pull/40), OPEN / NON-DRAFT / UNMERGED.  
**Production status:** WITHHELD / NOT CERTIFIED. This section records read-only hosted observations and owner decisions; it does not authorize merge, deployment, hosted migration, restore, or production mutation.

### 24.1 Exact-head engineering evidence

All three required workflows completed successfully on the same exact SHA, `58a67702efa2167c2060bb3e40d37880b7b6b00d`:

| Workflow | Run | Result |
|---|---:|---|
| AiOS CI | [45049001169](https://github.com/Neuracoderepo1/AiOS/actions/runs/45049001169) | SUCCESS, 4/4 jobs |
| ET27 seal guard | [45049001172](https://github.com/Neuracoderepo1/AiOS/actions/runs/45049001172) | SUCCESS, 1/1 job; 303 checks, 0 failures; 48/48 mutants detected |
| ET27 delete protection | [45049001252](https://github.com/Neuracoderepo1/AiOS/actions/runs/45049001252) | SUCCESS, 1/1 job; 66 checks, 0 failures; 10/10 mutants detected |

AiOS CI's four successful jobs were `evidence-integrity`, `functions-behavioral`, `functions-typecheck`, and `migrations-and-sql-tests`. The SQL/migration job passed the full 131-migration replay, real-PostgreSQL export/isolated restore, SQL tests including 21 and 22, the 46-case canonical matrix, mission/task and approval concurrency suites, audit-lock interleavings, smoke self-test (86/86), and approval-chain post-lock binding revalidation across 10 fresh migrated databases (10/10). The Part E log records E02.8/E02.8a passing for non-UTC append verification and the UTC-pinned audit writer. Test 22 reports the tenant-scoped authenticated owner audit-verification regression passing.

### 24.2 Exact-head evidence artifacts

GitHub artifact metadata reports the following unexpired artifacts bound to the exact SHA above. Digests are GitHub-reported; this checkpoint does not claim independent ZIP re-hashing.

| Workflow | Artifact | ID | GitHub-reported SHA-256 |
|---|---|---:|---|
| AiOS CI | `aios-ci-evidence` | 14764379287 | `591052b40ecb1fb3b9b7aebe714035a6bbf4a6f93eca78c84772b06f651b2f20` |
| AiOS CI | `behavioral-evidence` | 14765021178 | `81dcbba7f7c4566dddd65e48b177a2cdba96ca9c3138f04de9963a0860b2fa72` |
| ET27 seal guard | `et27-seal-guard-evidence` | 14764946686 | `4975a6c92cbf91c206252bf526104c3d2bbadce084ce6a6d5d3485a89629fe90` |
| ET27 delete protection | `et27-delete-protection-evidence` | 14765006490 | `92814ecfeff486bc78e0d4a59e4ed4e8cbc954878aa8dbc9dfbf1067d4d6b882` |

Agent 003 independently reviewed this exact candidate on 22 November. Its written determination accepts F-40-08 at source/real-PostgreSQL test-evidence level, accepts F-40-10 at candidate source/CI level, and confirms F-40-09 closed at its prior documentation checkpoint. It does **not** certify production. It specifically identified this document's section 23.1 workflow-pending wording as stale; this section records the actual successful exact-head runs. Agent 003's review also confirms that the CI JWT owner fixtures are disposable tests, not genuine hosted owner-session evidence.

### 24.3 Fresh read-only hosted observation — 22 November, approximately 19:58 UTC

Hosted project: `jtkcdwhiduixoiodhbfn`. No production writes were performed.

| Check | Observation |
|---|---|
| Applied migration versions | 117; latest `20261108130000`, matching the 117-file `origin/main` inventory |
| Candidate migration files | 131; 14 remain unapplied |
| RLS | Enabled on all 17 public base tables and the 1 private base table |
| Scheduled jobs | `aios-reap-stale-tasks` and `aios-expire-stale-approvals`, both active at `*/5 * * * *` |
| Security advisor | Three existing authenticated SECURITY DEFINER warnings; leaked-password protection disabled (budget deferral); INFO for `private.aios_trusted_executors` RLS with no policy (deny-by-default) |
| Client-executable functions | 16 across public/private; SECURITY DEFINER functions pin empty search_path. Confirm intended exposure of invoker `public.aios_risk_rank` to anon with `search_path=public`, and `public.verify_audit_chain` to authenticated |

The 14 unapplied versions, in order, are: `20261108140000`, `20261108150000`, `20261109120000`, `20261109130000`, `20261110100000`, `20261111170000`, `20261111190000`, `20261111200000`, `20261111210000`, `20261111220000`, `20261111230000`, `20261113160000`, `20261120180000`, and `20261120190000`.

Read-only preconditions at the observation time: zero succeeded missions with live tasks, invocations, or approvals; zero succeeded missions overall; zero tasks outside the new allowed status set; zero running tasks. In-flight work was 10 queued tasks, 3 queued missions, 1 pending approval, 4 requested invocations and 2 requires-approval invocations. These are point-in-time observations and must be rechecked immediately before any authorized migration window.

**Unresolved hosted parity item:** the hosted schema/function-definition/grant catalog has not yet been compared with a clean replay. That comparison is scheduled after authorized migration execution, against the final hosted state. The hosted observation does not establish catalog parity.

### 24.4 Migration-content delta requiring exact-head evidence

Migration `20261109130000_aios_audit_anchoring_part_e.sql` gained 245 lines after the last previously evidenced SHA `03495472bf7ec40a2ca4e4fec8e63fb42a34224e`. The current exact-head CI on `58a6770...` now validates the 131-file candidate tree, including this migration, and passes the Part E SQL suite. The 245-line change must remain explicitly tied to the exact-head CI and artifact evidence in 24.1–24.2; evidence from the earlier SHA must not be substituted.

### 24.5 Owner decisions and budget-neutral controls

The Human Director's recorded decisions for this candidate are:

- **External attestation:** retain classification `EXTERNAL_DEPENDENCY_BLOCKED` as documented residual risk for this release candidate. Release language may say the audit chain is **internally verified**; it must not claim external or certification-grade attestation until a TSA/RFC 3161 trust root is selected and exercised.
- **Backup/recovery:** re-scope the evidence gate to a budget-neutral logical dump and restore exercise. Supabase Free has no managed backups or PITR, and no paid upgrade is authorized. The compensating control is a schema-and-data logical dump immediately before migration, restored into a disposable local stack and compared with the content fingerprints, with measured RTO recorded. This exercise has **not yet been performed**. Release language must say: **“No managed backup or PITR; logical-dump recovery exercised once”** only after the exercise actually succeeds. Trigger to purchase PITR: first paying customer or any non-demo tenant data. This is a re-scoping decision, not evidence that recovery is complete.
- **Staged migration plan:** the version-ordered 14-migration plan is approved as a plan only; execution remains held behind the gates below. The intended application path is merge through the existing Supabase deploy pipeline to preserve exact migration versions. Do not apply through MCP or SQL editor, which would bypass the reviewed pipeline and risk migration-version parity.

### 24.6 Remaining release gates and execution order

| Gate | Required evidence / action | Authority |
|---|---|---|
| G1 | Freeze exact head; all three workflows green on one identical SHA with clean artifacts | Agent |
| G2 | Written Agent 003 disposition on that exact SHA | Agent 003 |
| G3 | Pre-migration schema + data logical dump, restore into disposable local stack, compare with freshly captured fingerprints, record measured RTO | Human Director controls execution/evidence |
| G4 | Immediately-before-window check: zero running tasks; record queued work and pending approval | Agent |
| G5 | Merge PR #40 through the existing approved stack/deploy path, thereby applying the 14 migrations | Human Director only |
| G6 | Post-deploy verification: 131 migration versions, latest `20261120190000`; zero unexplained schema/function/grant diff versus clean replay; both existing cron jobs intact; advisor diff limited to expected findings; compare fingerprints for expected-only changes; rerun 46-case matrix and smoke suite | Agent |
| G7 | Genuine owner sign-in and F-40-10 procedure; record real actor ID, organization ID, JWT subject and result. No service-role substitute or simulated owner identity | Human Director only |

G1 and the engineering portion of G2 have evidence at `58a6770...`; Agent 003's latest review nevertheless requires this documentation correction and review of the successor. G3, the immediate G4 window check, G5, G6 and G7 remain outstanding. No gate is implied complete merely because it is listed here.

There are no down-migrations. Recovery is forward-fix or restoration from the G3 dump. Stop on any error and do not proceed to the next migration. The observed data scale was approximately 190 audit events, 56 invocations and 30 approvals; these are estimates from the observation, not a guarantee of unchanged counts at execution.

### 24.7 Owner-only evidence and governance

The Human Director must supply current owner-level branch-governance evidence (branch protection and organization rulesets, including required reviews, bypass actors and administrator enforcement), and a short-lived read-only fine-grained GitHub token if further exact-head artifact/API inspection is required. No token or secret is to be pasted into chat. The earlier branch-protection observations are not a substitute for complete owner-level evidence.

### 24.8 Release boundary

PR #40 remains OPEN / NON-DRAFT / UNMERGED. Production certification remains **WITHHELD / NOT CERTIFIED**. F-40-08 is accepted at source/CI evidence level; F-40-09 is closed at the previously reviewed documentation-reconciliation level; F-40-10 is accepted at candidate source/CI level only. Genuine hosted owner-session proof, G3 recovery exercise, hosted parity after migration, owner-level branch-governance evidence, and the separately authorized migration execution remain outstanding.

No merge, deployment, hosted migration, production export/restore, production data write, role/grant/RLS/policy/trigger/cron/Auth change, secret change, billing change, paid plan upgrade or production configuration change was performed or authorized by this checkpoint. **Access is not authority.** Agent 004 implements and supplies evidence; Agent 003 independently reviews and certifies.


### 24.9 Final exact-head ET27 delete-protection retry — 22 November 2026

The first ET27 delete-protection attempt for candidate `d02b00afc8cbb3ca151964374671ba4cfb17104e` failed during disposable local Supabase startup because Docker could not bind `0.0.0.0:54322`; the delete-protection suite did not execute. GitHub's failed-job-only retry then completed successfully on the same exact SHA. All 11 job steps passed, including full 131-migration replay, startup-log credential-redaction verification, the delete-protection suite, evidence upload and cleanup. The retry produced artifact `et27-delete-protection-evidence`, ID `14772381473`, GitHub-reported SHA-256 `8cb50b64bd1b59eab279f9bdd8854917572c2dbfbd6ca1841c00e4e0c6d21b7f`. The earlier failed-attempt diagnostic artifact ID `14770714857` is not passing evidence and is excluded from the release evidence set.

Together with the AiOS CI and ET27 seal-guard runs in 24.1, all three required workflows now have successful results and unexpired artifacts bound to the same exact candidate SHA. This is engineering evidence only; it does not alter the production certification or owner-controlled release gates above.


## 25. F-40-09 successor reconciliation and PR stack snapshot — 22 November 2026

**Reference head:** `f0f0b203e43166efa312ba9338b5ac59a113b3e1` on `agent004/mission-cancellation-contract`. This section is a documentation-only successor record. It does not rewrite historical evidence or change the production release hold.

### 25.1 F-40-09 disposition clarification

The earlier statement in section 21.4 that F-40-09's independent disposition was pending describes the checkpoint at evidence SHA `03495472bf7ec40a2ca4e4fec8e63fb42a34224e`; it is historical, not the latest disposition. Section 22.1 records Agent 003's later disposition of **F-40-09 CLOSED at documentation-reconciliation level**. Section 24.6 carries that disposition forward while expressly preserving the requirement for Agent 003 to review a later documentation successor.

Accordingly:
- F-40-09 remains **CLOSED at documentation-reconciliation level** under the recorded Agent 003 disposition.
- This clarification does not certify the current documentation commit, the new successor, the product, or production.
- Each documentation successor must receive its own three exact-head workflows and any required Agent 003 re-review. Evidence from `f0f0b203` or earlier SHAs cannot be transferred to its successor.
- Historical references to `03495472`, `dd72de93`, and the pending disposition are retained as historical checkpoint records; this section is the current interpretive rule.

### 25.2 Exact-head CI on the reference head

The three pull-request workflows associated with reference SHA `f0f0b203e43166efa312ba9338b5ac59a113b3e1` completed successfully:
- AiOS CI: run `45068329781`, 4/4 jobs successful.
- ET27 seal guard: run `45068329782`, 1/1 job successful.
- ET27 delete protection: run `45068329795`, 1/1 job successful.

GitHub artifact metadata for each run binds the artifacts to the reference SHA. These are predecessor evidence only and do not validate the documentation successor created after this checkpoint.

### 25.3 PR stack reconciliation

The following metadata was read from GitHub PR records on 22 November 2026. The base/head SHA links confirm the intended dependency chain; no PR state or base was changed.

| PR | Base → head branch | Base SHA | Head SHA | State | Stack role |
|---:|---|---|---|---|---|
| #29 | `main` → `feat/aios-restoration-audit-anchoring` | `bef031f2e084f9f327611dc5275c0ee56dfe0cb9` | `4275c70021bae9c65752916578c9f2cd3615200f` | OPEN / DRAFT / UNMERGED | Root candidate on main |
| #31 | `feat/aios-restoration-audit-anchoring` → `agent004/p1-restoration-role-repair` | `4275c70021bae9c65752916578c9f2cd3615200f` | `b4543ebfe2accc191cf08a7e4f1b2976f0d7b664` | OPEN / NON-DRAFT / UNMERGED | Child of #29 |
| #34 | `agent004/p1-restoration-role-repair` → `agent004/p0-p1-integrated-candidate` | `b4543ebfe2accc191cf08a7e4f1b2976f0d7b664` | `8c7307b537062a87bd819ccede74e1dfc1eb8f5a` | OPEN / DRAFT / UNMERGED | Integration child of #31 |
| #35 | `agent004/p0-p1-integrated-candidate` → `agent004/f2-reaper-record-isolation` | `8c7307b537062a87bd819ccede74e1dfc1eb8f5a` | `2b96b281cdea510cf0a5c42df24a53460e549776` | OPEN / DRAFT / UNMERGED | F-2 child of #34 |
| #40 | `agent004/f2-reaper-record-isolation` → `agent004/mission-cancellation-contract` | `2b96b281cdea510cf0a5c42df24a53460e549776` | `f0f0b203e43166efa312ba9338b5ac59a113b3e1` | OPEN / NON-DRAFT / UNMERGED | Mission-cancellation child of #35; documentation successor pending |

**Required dependency order:** #29 → #31 → #34 → #35 → #40. Do not merge a child independently or collapse the stack. All five PRs remain open and unmerged; #29, #34 and #35 are drafts; #31 and #40 are non-drafts. This table is a metadata reconciliation, not merge authorization.

### 25.4 Release boundary

The Release Hold Record v2 remains ACTIVE. Hosted database access, migration execution, deployment, merge, production configuration or privilege changes, and any claim that a hosted gate has passed remain outside this work. Production certification remains **WITHHELD / NOT CERTIFIED**. Agent 004 supplies implementation and evidence; Agent 003 independently reviews and certifies.
