# AiOS approval-expiry change: operational certification report

Date: 2026-11-03 | Change: PR #7 (merge commit `e123e4a`) | Production project: `jtkcdwhiduixoiodhbfn`
Status: **CERTIFIED WITH DOCUMENTED EXCEPTIONS** (evidence items in section 4 closed 2026-11-03).

## 1. Owner decisions (recorded)

| Subject | Decision |
|---|---|
| matrix-v1, its manifest, evidence and integrity pins | Preserved, unchanged. No matrix-v2. |
| Test 09 (`tests/sql/09_approval_mandatory_expiry_regression.sql`) | Accepted as an additive regression test outside the canonical manifest |
| Approval `8c47bb48-fb79-48a8-9527-43467f4a67c6` | Retain quarantine. Do not approve, delete, rewrite history, or bypass the organization-integrity guard |
| Mission `b3c24435` "Analyze latest customer support dataset" | Keep the recorded cancel (`owner_decision_cancel`, owner:derrick-morris, 2026-11-02; mission status `cancelled`). No new decision record |
| Task `281be61d` "Identify the five largest recurring customer-support problems" | Keep the recorded cancel (`owner_decision_cancel`, owner:derrick-morris, 2026-11-02; task status `cancelled`). No new decision record |

## 2. What changed

- Trigger `trg_aios_approval_default_expiry` (BEFORE INSERT OR UPDATE OF expires_at, status) on `public.aios_approvals`: a pending approval inserted without an expiry receives `now() + 24h`; clearing the expiry of a pending approval that has one is rejected (SQLSTATE 23514).
- Function `private.aios_approval_default_expiry()` is SECURITY DEFINER, `search_path` pinned empty, executable by owner only.
- An interim CHECK constraint was applied and then replaced the same day, because CHECK constraints also fire under `session_replication_role = replica` and broke the legacy-shaped fixtures in tests 03, 08 and matrix case F7. It is absent from production (verified).
- Authorization, resolver and janitor logic are unchanged. Authorization already rejected NULL expiry (`valid approval required`).

## 3. Verified evidence

| Control | Evidence | Result |
|---|---|---|
| Expiry generated | Test 09 N1 | pass |
| NULL expiry cannot be written to a pending approval | Test 09 N2 | pass |
| NULL-expiry approved row cannot authorize | Test 09 N3 | pass |
| Expired approval rejected server-side | Test 09 N4, matrix F4 | pass |
| Resolved approval immutable | Test 09 N5 | pass |
| Contract version revalidated | Test 09 N6, matrix D4 | pass |
| Stale-approval cleanup function exists, scheduled every 5 min, converges legacy NULL rows | Test 09 N7, tests 01/03/08, `cron.job_run_details` (latest run succeeded 2026-11-03 06:25 UTC) | pass |
| Existing suites 01-04, 06-08 | Rollback-only runs on production | pass |
| Canonical matrix | Rollback-only run on production | 45/45 pass |
| Integrity pins | `verify_integrity.py` with `matrix-v1.pins`; mutation tests 8/8 | pass |
| CI on PR head `398ebab` | `migrations-and-sql-tests` (fresh-DB migration replay, all `tests/sql/*.sql`, canonical matrix step), `evidence-integrity`, `functions-typecheck` | success |
| Production state vs repository | Live trigger definition, absence of the CHECK, function ACL match `20261102215948`; all migrations through `20261102215948` present in production | reconciled (see note) |

Reconciliation note: three earlier migrations carry different version stamps in production (`20261102062924`, `…062928`, `…064034`) than in the repository (`20261102090000`, `…091000`, `…100000`), and production's `20261102062940` (view select-only) is folded into the repository's view migration. This is recorded in `docs/certification/AGENT-003-HANDOVER.md`. Names and effects match; stamps differ.

Live-database test adjustment: tests 03 and 08 were run on production with their expected "invalid bindings skipped" count raised by one to account for the quarantined approval `8c47bb48`. CI runs them unmodified on a fresh database.

## 4. Evidence items (closed)

1. **G4 eight-way concurrency.** `ci.yml` runs it inside the step "Canonical test matrix (46 cases)" (matrix 45 SQL cases + G4, verified against `tests/matrix/manifest.json`). That step concluded `success` on the PR run (https://github.com/Neuracoderepo1/AiOS/actions/runs/41534539112) and on the `main` push run (https://github.com/Neuracoderepo1/AiOS/actions/runs/41534944843). The step's raw log and `report.json` were not downloaded; the conclusion was read from the Actions API.
2. **CI on merge commit `e123e4a`.** `AiOS CI` (push) concluded success: `functions-typecheck`, `evidence-integrity`, `migrations-and-sql-tests` (fresh-DB replay of all migrations, all `tests/sql/*.sql`, canonical matrix) all success.

Known failing external check: **Supabase Preview** reports "Remote migration versions not found in local migrations directory". It also failed on the previous `main` commit (`75c1f98`), so it predates this change. Cause: three production migrations carry different version stamps than the repository (see section 3 reconciliation note). Resolved by renaming the three repository migrations to production's versions and adding production's `20261102062940` file (repository and production now both hold 113 migrations with identical versions).

## 5. Accepted exceptions

- Approval `8c47bb48` remains pending with NULL expiry (agent_organization_mismatch, quarantined, three manual-review dispositions, append-only history intact). The janitor skips and reports it every run by design.
- Six legacy invocations (`requested` x4, `requires_approval` x2, created 22-24 Aug; tools `execute_two_leg_arb`, `withdraw_funds`, `Python`) have no approval and no disposition. They cannot authorize without a valid approval; classification is a follow-up.
- Mission `b3c24435` and task `281be61d` are cancelled by recorded owner decision (history append-only, original manual_review rows preserved).
- Legacy invocations cannot be recorded in `aios_backlog_dispositions` (entity types are limited to approval, task, mission); classifying them needs a schema decision, not just an owner decision.
- Four historical approved approvals have NULL expiry. They are sealed and cannot authorize (N3).
- Leaked-password protection remains off (budget decision, unchanged).

## 6. Conclusion

The NULL-expiry gap is eliminated for all new and updated approvals and is covered by regression tests. With the evidence items in section 4 closed, the approval-expiry change is certified for production, with the exceptions in section 5 owner-held and the Supabase Preview version-stamp mismatch closed by follow-up PR (migration versions aligned).
