# PR #28 — Audit-Lock Deadlock Remediation (P0)

Author: Agent 004 | Subject commit: `e6c7b9a51ce8d6d4ff24fd4d7349cf874409cbe4` (fix/l3-audit-lock-order) | Date: 2026-11-11 UTC
Evidence: `docs/certification/closure/evidence/p0/` | Reviewer: Agent 003 — **PENDING REVIEW**
**Evidence level reached: 2–3 (local PostgreSQL, full migration replay). Levels 4 (CI on these commits for the new test) and 5 (real Supabase) NOT RUN.**

## 1. Environment (see ENVIRONMENT.txt)
- PostgreSQL 16.15 (Ubuntu), `deadlock_timeout=1s`, throwaway cluster, local socket trust auth.
- `pg_cron` and `pg_jsonschema` are **local stand-ins** (the real extensions are not installable offline). Results are therefore **supplemental**, per the directive's evidence hierarchy. They do not substitute for real Supabase.
- Full replay of all 120 migrations succeeded on the #28 head (`applied=120 fail=0`); pre-fix replay (without `20261110100000`) `applied=119 fail=0`.

## 2. Root-cause verification (Level 1 + 2)
Hypothesis confirmed against the actual functions and by a forced interleaving, not by inference:
- Pre-fix, `aios_expire_stale_approvals` writes audit for the first approval (acquiring the org-wide audit advisory lock, held to commit) and only then waits for a later approval's mission row lock held by a cancelling session, whose UPDATE in turn needs the audit lock. The test records `E_holds_audit_lock_while_waiting_for_a_row=1` and a real `40P01`.
- Post-fix, the job locks every candidate's mission subtree (mission→task→invocation→approval, ordered) in a phase with no audit writes, so it waits holding no audit lock: `...=0`, `deadlocks=0`.

## 3. Forced-test results (deterministic event barriers; no sleeps as evidence)
Each suite was run on a freshly replayed database per side.

| # | Requirement | Test | Pre-fix (must fail) | Post-fix (must pass) | Log |
|---|---|---|---|---|---|
| 1 | Pre-fix audit-lock deadlock reproduction | l3_audit_lock_forced | FAIL, deadlocks=1, holds-audit-lock=1 (exit 1) | PASS (exit 0) | l3_audit_lock_forced.*.log |
| 2 | Expiry vs cancellation | l3_audit_lock_forced | as above | PASS: cancel commits, A1 expired, M2 chain consistent | same |
| 3 | Reaper vs cancellation | l4_reaper_audit_lock_forced | FAIL, deadlocks=1, reaper rc=1 (exit 1) | PASS | l4_reaper_audit_lock_forced.*.log |
| 7 | Lock-conflict deferral | l3_lock_conflict_deferral | FAIL (conflict recorded as disposition) | PASS: deferred+counted, no disposition | l3_lock_conflict_deferral.*.log |
| 8 | Subsequent successful retry | l3_lock_conflict_deferral run 2 | n/a | PASS: A1 expired on next run | same |
| 9 | Non-transient error handling | l3_lock_conflict_deferral | n/a | PASS: A2 still gets manual_review disposition (existing behavior preserved) | same |
| 10 | No permanent incorrect manual-review disposition | l3_lock_conflict_deferral | FAIL | PASS | same |
| 4/5/6 | Multi-mission, multi-org (2 orgs × 3 missions), repeated concurrent expiry batches (4 workers vs cancels) | l3_multi_org_concurrent_batches (**new**, stress) | 6 of 30 rounds FAIL with lock-class errors; 2 rounds also wrote a permanent `manual_review` disposition for a lock conflict | **30 of 30 rounds PASS**, 0 lock-class errors, 0 dispositions | multi-org-stress.*.log |

Notes on #4–#6: this suite is a **stress** test and is scheduler-dependent. It is supporting evidence only; the deterministic suites above are the proof. Its oracle tolerates exactly one application-level rejection: a cancel refused by the state guard (`P0001 invalid mission state transition: failed -> cancelled`) because the expiry already failed the mission. That is correct terminal-state protection and is counted and classified, not ignored; any other worker failure is a defect. Each round must also expire ≥1 approval (no vacuous pass).

## 4. Mutation results (Level 2)
`tests/harness/mutate_l3_l4.sh`, three controls pass and all three mutations are killed:

| Mutation | Test that must fail | Result |
|---|---|---|
| M1 remove expiry pre-lock | l3_audit_lock_forced | KILLED |
| M2 remove reaper pre-lock | l4_reaper_audit_lock_forced | KILLED |
| M3 reintroduce swallowed lock conflicts | l3_lock_conflict_deferral | KILLED |

Caveat (open for Agent 003): the battery treats any nonzero, non-2 exit as "killed". It does not assert *why* the test failed. A mutation killed by an unrelated error would be miscounted. Recommended hardening: assert the specific failing check name per mutation.

## 5. Transient SQLSTATE coverage
`aios_is_lock_conflict` covers 40P01, 40001, 55P03, 57014 (static inspection). Only **40P01** is exercised by a forced test. 40001, 55P03 and 57014 are covered by inspection only — **NOT RUN** as forced tests.

## 6. Certification rows
| Requirement | Test | Expected | Actual | Status |
|---|---|---|---|---|
| Pre-fix reproduces deadlock | l3/l4 forced (pre) | FAIL | FAIL | PASS |
| Post-fix no deadlock | l3/l4 forced (post) | PASS | PASS | PASS |
| Deferral not disposition | l3_lock_conflict_deferral | PASS post / FAIL pre | as expected | PASS |
| 3 mutations detected | mutate_l3_l4 | 3 KILLED | 3 KILLED | PASS |
| Multi-org stress | l3_multi_org_concurrent_batches | 30/30 | 30/30 | PASS (supplemental) |
| 40001/55P03/57014 forced behavior | — | defer | not exercised | NOT RUN |
| CI on exact commit incl. new test | AiOS CI | green | not wired / not run | NOT RUN |
| Real Supabase integration | — | — | unavailable | BLOCKED |
| Independent review | Agent 003 | — | — | PENDING REVIEW |

## 7. Open items
1. New stress test is not wired into CI (`ci.yml`); to be added on the integration branch and run on GitHub Actions.
2. Forced tests for 40001/55P03/57014 not written.
3. Mutation oracle strength (see §4).
4. Everything here ran on stand-in extensions and plain PostgreSQL; no real-Supabase claim is made.
