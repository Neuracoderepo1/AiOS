# Execution-authority races: findings, fix and evidence (Stage B, partial)

Status: **PROPOSED, NOT DEPLOYED.** Merging this PR to `main` triggers the Supabase deployment and would apply the new migration to
production. It needs Human Director authorization and a green run of the real CI on this branch. Nothing here has been merged or deployed.

Baseline inspected: `main` @ `edea49d2fc7d3356511e657a7df9010648ef61c2` (reproduced: HEAD matched).

## Findings (reproduced on real PostgreSQL 16, event barriers, no sleeps as proof)

| ID | Severity | Finding | Evidence (pre-fix) | Post-fix |
|---|---|---|---|---|
| F-1 | High (kill-switch can lose a race; fail-visible, not a silent bypass) | Lock-order inversion. Authorizer locks invocation → task → mission; the mission terminal cascade locks mission → approvals → invocations → tasks. PostgreSQL aborted the **mission cancellation** with `40P01` while the executor reached `executing`. | R1 forced interleaving: B (cancel) aborted `deadlock detected`, final `running/running/executing`. R1b: **5 deadlocks in 8 simultaneous pairs**, 4 of 8 chains inconsistent. | 0 deadlocks, 8/8 cancels committed, 0 inconsistent; 3 of 3 repeat runs. |
| F-2 | Medium (state hygiene; the kernel still refused execution) | No task-level terminal cascade: cancelling a task directly left its invocation `approved` and any pending approval `pending` (orphan, property G). | R2: `running/cancelled/approved`. | `running/cancelled/cancelled`. |

Not a finding, checked and rejected: the claim that the DB layer lacks cross-row mission/task enforcement. It does
(`aios_assert_invocation_executable`, `trg_aios_task_mission_gate`, `trg_aios_mission_terminal_cascade`, migration `20261106193358`).

## Fix (single global lock order: mission → task → invocation → approval)

`supabase/migrations/20261108140000_aios_execution_lock_order_and_task_terminal_cascade.sql`: authorizer prologue
(`private.aios_lock_execution_chain`), new `aios_task_terminal_cascade`, mission cascade reordered. No check is removed or weakened;
`aios_assert_invocation_executable` is unchanged and remains the authority. The task cascade stands down when the parent mission is terminal
so the existing `MISSION_TERMINAL` audit attribution is preserved.

## Test: `tests/concurrency/mission_task_races.sh`

Event barriers: `pg_stat_activity.wait_event_type='Lock'` for "B is blocked", sentinel rows for "step done", advisory-lock gate released
once all workers are observed parked. Fails closed on a broken fixture (a vacuous pass was found and fixed during development: empty ids
once produced a PASS; cancel counts are taken from committed state, not worker output).

## Verified here vs not verified here

Local environment is **not** the Supabase stack: Postgres 16.15 with shims (no-op `pg_cron`, a JSON-Schema-subset stand-in for `pg_jsonschema`,
minimal `auth`). Treat local numbers as development evidence only; **CI on this branch is the authority.**

| Item | Local (shim) | Authoritative |
|---|---|---|
| 117/117 migrations replay | PASS | CI required |
| tests/sql 01–09 | PASS (also after the new migration) | CI required |
| tests/sql 10, 11 (ET27) | FAIL on shim, identical before and after the migration; shim limitation | **NOT VERIFIED locally; use CI** |
| Existing G4 8-way + expiry race | PASS after migration | CI required |
| New race test | red pre-fix, green post-fix, 3/3 | CI required |

## Open items (not done in this change)

1. Remaining race classes from the directive are **not yet built**: expiry vs claim, approval withdrawal vs execution, cancel during model call, cancel after tool before completion, concurrent completion vs cancel, reaper vs active tasks, duplicate execution, compensation vs terminal. (Only R1/R1b/R2 exist.)
2. Lock order of `aios_resolve_approval`, `aios_expire_stale_approvals` and the reaper against the new global order is **unreviewed**.
3. PR #18 (handler fixes) is open and unmerged; I reviewed it and agree with its design, but D5/D6 (zero-row results ignored at the `blocked_pending_approval` and tool-failure writes) are not in it.
4. The 87-test behavioral suite and 23 mutants live only on unmerged branches (`test/edge-function-behavioral`, `test/behavioral-terminal-race-coverage`), not on `main`, so they could not be reproduced from `main`. Deno is not installed here and package installs are disabled.
5. Production HTTP gate S1/S2/C1/H1–H5: **BLOCKED**. Latest run failed with `503 ANTHROPIC_API_KEY is not configured`; H3/H3b are a cascade of H1 producing no invocation id. No secret was read, set or changed.
