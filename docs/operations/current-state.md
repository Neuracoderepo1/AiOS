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
