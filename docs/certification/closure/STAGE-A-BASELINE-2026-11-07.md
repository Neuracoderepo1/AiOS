# AiOS Production Closure: Stage A Baseline

- Status: **PRODUCTION CLOSURE IN PROGRESS**
- Authored by: Agent 004 (implementation). This is evidence, not certification; Agent 003 must independently verify.
- Candidate commit inspected: `d5436df1895494a4905f8605a2cc71e405d43ecb` (main, merge of PR #11)
- Production project: `jtkcdwhiduixoiodhbfn`, inspected **read-only** on 2026-11-07 ~18:54 UTC
- Production was NOT modified. No migrations applied, no functions deployed, no records changed.

## 1. Migration parity (G1)

| Item | Result |
|---|---|
| Production recorded migrations | 115 |
| Repository main | 113 |
| Diff | exactly 2 production-only: `20261106193358`, `20261106195638`; nothing repo-only |
| Production provenance | both applied via migration API by `unyxmusic@gmail.com`; no rollback |
| Authorization of that application | **UNKNOWN. Human Director decision required** (the database cannot say) |

Content check of PR #16 (head `bef5f15c`) against production `supabase_migrations.schema_migrations`:

| Version | Production statements md5 | PR #16 file md5 (trailing newline stripped) | Match |
|---|---|---|---|
| 20261106193358 | 205917628fc8a76e55d5ecb77758389b | 205917628fc8a76e55d5ecb77758389b | yes |
| 20261106195638 | 81a7f7d59bca3908948931b738690831 | 81a7f7d59bca3908948931b738690831 | yes |

The files are one byte longer than the stored statements (final newline only). PR #16 is still **draft/unmerged**. Its CI `migrations-and-sql-tests` passed. A clean-replay-to-production **schema diff** has not yet been done.

## 2. Execution handler (G2, G3): defects confirmed in deployed source

Deployed `execute-task` v23 was read and compared by marker to repo main; all key markers are present (no gross drift). **Byte-level deployment parity is not yet proven.**

Gaps against the Phase Two requirements:

| # | Requirement | Finding |
|---|---|---|
| 1 | Validate parent mission before progressing | The handler never reads mission status. FAIL |
| 4 | Confirm conditional mission-start update affected a row | `update ... eq(status,queued).select(id)` checks `error` only, never the row count. FAIL |
| 5/6/9 | Revalidate state after the model call; stop on terminal | No revalidation between claim, model proposal, and kernel authorization. FAIL |
| 10 | Task-completion must confirm the row was updated | `update ... eq(status,running)` checks `error` only. If a cascade cancelled the task meanwhile, 0 rows update and the handler still returns **200 "completed"**. FAIL |

Mitigating (database layer, from migration `20261106193358`): the kernel now calls `aios_assert_invocation_executable` (task and parent mission, fail-closed), a mission-terminal cascade cancels live tasks, approvals and non-executing invocations, and a trigger blocks live tasks under terminal missions. This stops a new invocation after the mission goes terminal.

Residual race (needs proof against real Postgres): a mission becoming terminal **after** kernel authorization but **during** tool execution. The cascade does not cancel `executing` invocations, so the tool side effect can complete and the handler then reports success for a cancelled task.

## 3. Security and advisors (G8)

- 3 SECURITY DEFINER warnings still open: `aios_agent_trust_explain(uuid)`, `aios_current_org_role(uuid)`, `aios_public_metrics(uuid)`. Not yet individually reviewed.
- Leaked-password protection: disabled. Remediation path to be established.
- INFO: `private.aios_trusted_executors` has RLS enabled with no policy (deny-by-default; intended, to be documented).
- 24 unused-index notices (performance). Not yet analysed; none removed.

## 4. Approvals and cron (G5)

- Approvals: pending 1, approved 4, expired 22, rejected 1. Statuses unchanged from the earlier snapshot.
- The one pending approval (`8c47bb48-fb79-48a8-9527-43467f4a67c6`) has `expires_at` NULL, `task_id` NULL, created 2026-08-25. **Not modified.** Disposition requires a Human Director decision.
- Cron `aios-reap-stale-tasks` (every 5 min): 6993 runs, 0 non-success.
- Cron `aios-expire-stale-approvals` (every 5 min): 6926 runs, **13 non-success**. This corrects the earlier "all successful" snapshot. All 13 failed within 2026-11-01 22:20 to 23:20 UTC with `approval agent organization mismatch` raised from `aios_validate_approval_integrity()`. Since the fix window: 1675 consecutive successes, 0 failures (last failure 2026-11-01 23:20:00 UTC). Root cause is attributed to migration `20261101232313` by timing only; **to be confirmed** by reading it.

## 5. Pull requests

| PR | State | Head | CI on head |
|---|---|---|---|
| #13 launch-mission audit reason / compensation | open, draft | f25ac8a9 | migrations-and-sql-tests, evidence-integrity, functions-typecheck pass |
| #15 terminal-race behavioral coverage (base `test/edge-function-behavioral`) | open, draft | 07635f48 | typecheck, behavioral, sql-tests, evidence-integrity pass |
| #16 migration parity | open, draft | bef5f15c | typecheck, sql-tests, evidence-integrity pass |

Review comments not yet read.

## 6. Gate register

| Gate | Status | Basis |
|---|---|---|
| G1 Migration parity | UNVERIFIED | content parity shown; PR #16 unmerged; schema-level parity not demonstrated |
| G2 Terminal-state enforcement | **FAIL (open)** | handler defects above |
| G3 Race-safe execution | **FAIL (open)** | residual race above |
| G4 PostgreSQL concurrency | UNVERIFIED | no real-Postgres race suite yet |
| G5 Approval authorization and expiry | UNVERIFIED | NULL-expiry pending record unresolved |
| G6 Audit-chain integrity | UNVERIFIED | production verification not run |
| G7 Edge Function correctness | UNVERIFIED | byte parity and coverage not proven |
| G8 Security hardening | UNVERIFIED | 3 DEFINER warnings, leaked-password protection open |
| G9 Recovery and operational readiness | UNVERIFIED | not started |
| G10 Regression and mutation evidence | UNVERIFIED | prior 87/23 results to be re-run on candidate |
| G11 Agent 003 verification | UNVERIFIED | not requested |
| G12 Human Director authorization | UNVERIFIED | not requested |

## 7. Decisions required from the Human Director

1. Was application of `20261106193358` and `20261106195638` by `unyxmusic@gmail.com` authorized?
2. Disposition of pending approval `8c47bb48-fb79-48a8-9527-43467f4a67c6` (NULL expiry, no task).
3. Authorization to merge PR #16 (no production effect).

## 8. Reproduction

All production queries were read-only `SELECT`s against `supabase_migrations.schema_migrations`, `cron.job`, `cron.job_run_details` and `public.aios_approvals`, plus the Supabase security and performance advisors. Hash check: `md5(array_to_string(statements, E'\n'))` versus the PR file with the final newline removed.

## Addendum 1 (2026-11-07 ~19:00 UTC): PR #16 merged

The sections above are preserved as written at the time of inspection. Subsequent change:

- PR #16 was merged into `main` at `3c09b90fbc9739edfd83c93768251b7b51443ab8` (merge commit) on the Human Director's instruction to proceed with merges. CI on PR #16 head `bef5f15c` was green, including the from-scratch migration replay (`migrations-and-sql-tests`).
- Repository `main` now carries the two migrations verbatim: 115 repo migrations vs 115 production.
- G1 remains **UNVERIFIED**: content parity (md5) and a green clean replay are shown, but a schema-level comparison of the replayed database against production has not been performed.
- Not changed: production; decisions 1 and 2 in section 7 are still open. This merge does not authorize the original 2026-11-06 production application, and does not resolve the NULL-expiry pending approval.
