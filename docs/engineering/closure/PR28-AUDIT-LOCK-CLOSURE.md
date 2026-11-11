# PR28-AUDIT-LOCK-CLOSURE

Agent 004, Phase Two, Priority Zero. **This report does not certify anything.** Independent review by Agent 003 is required.

| | |
|---|---|
| Repository / branch | `Neuracoderepo1/AiOS`, `fix/l3-audit-lock-order` (PR #28, draft, base `agent004/l3-evidence-hardening`) |
| Migration under review | `20261110100000_aios_batch_prelock_before_audit.sql` (unchanged by this work) |
| Product head reviewed | `e6c7b9a51ce8d6d4ff24fd4d7349cf874409cbe4` |
| Test/CI additions (this work) | `03ea6cb1defc364600facabe4e3f56ab7d99f010` (no migration or product code changed) |
| Migrations replayed | 119 up to the pre-fix point (`20261108150000`), 120 on the fixed head |
| Database | PostgreSQL 16.15 (Ubuntu), plain cluster + real `pg_cron` 1.6.2; **not Supabase** |
| Lock settings | `deadlock_timeout=1000ms`, `lock_timeout=0`, `statement_timeout=0`, `log_lock_waits=on`, `max_locks_per_transaction=64` |

## Status key
PASS / FAIL / BLOCKED / NOT RUN / PENDING INDEPENDENT REVIEW. Evidence is **local deterministic PostgreSQL only** (tier 2 of the evidence hierarchy) unless stated.

## 1. Executive status

| Question | Result |
|---|---|
| Is the L3 root cause independently reproduced? | **PASS** (pre-fix reproduced on real PG 16.15; see §2) |
| Does the fix remove it deterministically? | **PASS** (forced L3 and forced L4, event-barriered, no sleeps) |
| Lock conflicts deferred, not recorded? | **PASS** (expiry). **Not applicable to the reaper**: see F-2 |
| Non-lock errors keep previous handling? | **PASS** |
| Deferred record converges on next run? | **PASS** |
| Every subtree level is pinned by a test? | **PASS after this work.** Was **FAIL**: three of four levels were unpinned (F-1) |
| Reaper whole-job failure behaviour documented? | Was **FAIL** (undocumented). Now pinned by a test and described below; **design decision left to the Human Director** (F-2) |
| Supabase local stack | **BLOCKED** (no Docker daemon in this sandbox) |
| GitHub Actions on the exact commit | **NOT RUN** at time of writing (see §9) |
| Independent Agent 003 review | **PENDING INDEPENDENT REVIEW** |

Open findings: **0 critical, 0 high, 2 medium (F-1 closed by test, F-2 open), 2 low (F-3, F-4).**

## 2. Independent reconstruction of the deadlock (item 1)

Method: replay migrations only up to `20261108150000` (119 files), run the **unchanged** forced test `l3_audit_lock_forced.sh`.

Observed pre-fix (`evidence/pr28/prefix-l3-reproduction/`):
- Barrier: expiry job `E` blocked on a row lock held by cancel session `C`, **while `E` held the org audit advisory lock: YES**.
- Server log, SQLSTATE 40P01 (`LOG: process 2947 detected deadlock while waiting for ShareLock on transaction 1124 after 1000.147 ms`), DETAIL `Process holding the lock: 2940. Wait queue: .`, CONTEXT `while locking tuple (0,6) in relation "aios_missions"` via `aios_lock_approval_chain(uuid)` ← `aios_expire_stale_approvals()` line 24.
- **In this forced interleaving the deadlock victim was the expiry job's own per-record sub-transaction, not the cancellation.** Both worker processes exited 0. `E` returned `transition_errors_skipped: 1, defect: transition_error:40P01` and **durably wrote a `manual_review` row to `aios_backlog_dispositions`** for an approval that was merely a lock-conflict victim. The migration header names the cancellation as the victim. PostgreSQL aborts whichever backend's `deadlock_timeout` fires first, and here `E` had been waiting longer, so the victim is timing-dependent and **both outcomes must be considered possible**. The harm shown here is the permanent disposition; the header's failed-cancel outcome was not exercised.
- HINT is not available: the error was caught inside PL/pgSQL, so only the SQLSTATE survives into the job result. DETAIL and CONTEXT exist only in the server log.

Same test on the fixed head: `E` holds the audit lock while waiting: **NO**, deadlocks 0, cancel committed, expiry finished, A1 expired and A2's chain reconciled. **PASS.**

## 3. Requirement-by-requirement (items 2-9)

| # | Requirement | Result | Basis |
|---|---|---|---|
| 2 | Complete subtree locked before any audit write | **PASS** (expiry). Reaper: mission level only proven by test | static + `l3_audit_lock_forced`, `l3_audit_lock_subtree_levels`, M1/M4/M5/M6 |
| 3 | Order mission, task, invocation, approval | **PASS** (static): missions ascending id, then tasks/invocations/approvals each `ORDER BY id`; orphan approvals last | source, lines 24-58 |
| 4 | Candidate discovery takes no locks | **PASS** (static): plain `SELECT`, no `FOR` clause | lines 103-106, 232-233 |
| 5 | Predicates revalidated after locks | **PASS** (static): phase 2 re-selects with full predicate under READ COMMITTED; expiry re-checks again with `FOR UPDATE SKIP LOCKED` | lines 109-127, 236-244 |
| 6 | Lock conflicts deferred | **PASS** (expiry) | `l3_lock_conflict_deferral`, M3 |
| 7 | Non-lock errors keep handling | **PASS**: SQLSTATE `XX001` still yields `transition_errors_skipped` + `manual_review` | `l3_lock_conflict_deferral` |
| 8 | Deferred records converge | **PASS** | same test, run 2 |
| 9 | Reaper whole-job failure intentional and documented | **Not documented before.** Now pinned and described (F-2) | `l4_reaper_whole_job_failure` |

Caveats on 4 and 5: static findings only; no test injects a row that appears or changes between phase 1 and phase 2. Rows inserted into a locked subtree after phase 1 (a `KEY SHARE` FK insert does not conflict with `FOR NO KEY UPDATE`) are **analysis only, NOT RUN**.

## 4. Findings

**F-1 (medium, closed by test in this work). Three of four subtree lock levels were unpinned.** Removing the task-, invocation- or approval-level lock from `aios_lock_mission_subtree()` survived l3 forced, l4 forced, deferral, `approval_lock_order` and `mission_task_races`. Only the mission level was detected. The existing contender holds the mission row, so it can only ever notice that level. Fix: `l3_audit_lock_subtree_levels.sh`, a contender holding a lower-level row without the mission row, asserting the actual invariant (the job never waits for a row lock while holding the audit lock). Control passes; task-level (M4) and invocation-level (M5) mutants are killed.

**F-2 (medium, OPEN, Human Director decision). Reaper has no per-record isolation.** `aios_reap_stale_tasks()` has no exception handler. Any error, lock conflict or not, aborts the whole run; **everything already reaped in that run rolls back, audit events included** (verified). Retry is the next cron tick (every 5 minutes, `20261014120835`). One persistently failing task blocks reaping of **all** stale tasks (head-of-line blocking), with no counter or disposition. This differs deliberately from the expiry job. I could not establish from the repository that it is intentional. Pinned by `l4_reaper_whole_job_failure.sh` (non-lock and lock-conflict injections, atomic rollback, convergence on retry, audit chain valid). Not redesigned (out of scope).

**F-3 (low). Approval-level subtree lock is observationally equivalent in expiry.** With it removed, `E` never blocks: phase 2 takes the approval with `FOR UPDATE SKIP LOCKED` and skips it (`approvals_expired: 1`). It is defence in depth for this invariant, so this mutant cannot be killed by a lock-wait test and is **documented, not killed** (comment in `mutate_l3_l4.sh`). Consequence on the fixed code: the approval pre-lock makes `E` *wait* for an approval-row holder instead of skipping it.

**F-4 (low). `SKIP LOCKED` skips are invisible.** A record skipped by that clause is counted nowhere in the result JSON (`lock_conflicts_deferred` stays 0). It converges on a later run, but an operator cannot see it.

## 5. Test and mutation scorecard (local, PG 16.15)

| Test | Result |
|---|---|
| Forced pre-fix L3 reproduction (deadlock) | **PASS** (reproduced) |
| Forced post-fix L3 | **PASS** |
| Forced L4 reaper contention (post-fix) | **PASS** |
| Forced pre-fix L4 reproduction | **NOT RUN** directly; covered only indirectly by mutant M2 |
| Lock-conflict deferral + convergence | **PASS** |
| Non-lock-error regression | **PASS** (in the deferral test) |
| Subtree-level forced (task, invocation, approval) | **PASS** (new) |
| Reaper whole-job failure semantics | **PASS** (new) |
| Mutation battery | 5 controls pass; **M1-M6 killed**; 1 documented equivalent (F-3) |
| Repeated runs, 20 each x 5 tests = 100 | 100 pass, 0 fail; **0** server-side deadlock log lines. Supplementary only; not proof of race elimination |

Not run in this report: L4 reaper variants of the level test (expiry only); the PR #27 approval lock-order suite beyond the mutation probe (see PR27 report).

## 6. Known limitations and external dependencies

- **Not Supabase.** No Docker daemon, so the real local stack is **BLOCKED**. `pg_jsonschema` is a **harness stub**; `pg_cron` is real. Harness stubs are supplemental evidence only.
- The mutation battery is local-only and **not in CI**; the five forced/semantic tests now are (`ci.yml`).
- Everything above ran on one PostgreSQL minor version, single host.
- Nothing here exercises production data, configuration or credentials.

## 7. Handoff to Agent 003

Challenge in particular: the F-2 intent question; whether skipping rather than waiting in F-3 is acceptable; the unexamined post-phase-1 insert window (§3 caveat); and whether the pre-fix victim description in the migration header should be corrected.

## 8. Reproduction

`bash tests/harness/replay.sh <db> [upto]`, then `bash tests/concurrency/<test>.sh "host=/var/run/postgresql dbname=<db> user=postgres"`, `bash tests/harness/mutate_l3_l4.sh <db>`. Raw outputs: `evidence/pr28/`.

## 9. CI on the exact commit

**NOT RUN** when this file was written. The run ID and outcome for the commit that contains this report are recorded in the consolidated report, not here, because a report cannot cite the CI run of its own commit.

## 10. Confirmation

Nothing was merged, deployed, or applied to any Supabase project. No production data or configuration was touched. No history was rewritten or force-pushed.
