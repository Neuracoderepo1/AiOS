# Finding for Human Director authorization: execute-task does not consult the parent mission's status

Status: **OPEN. No production change made or authorized.** Raised by the Agent 004 behavioral-certification work.
Evidence basis: Deno behavioral probes (test double, not PostgreSQL) + static reading of source and migrations.
Nothing here was verified against a live database.

## F1: terminal parent mission is never checked (the known gap, now characterized)

`supabase/functions/execute-task/index.ts` reads the task (L182) and agent (L203), then claims the task (L214) and calls the model.
It never reads `aios_missions.status`. Every *write* to the mission is guarded (`status = queued` at L240, `status = running` at
L230/L351/L417), so the **mission row is protected**. The **task, the model call and the tool path are not**.

Observed (probe `gaps/terminal_mission.gap.ts`, 4/4 FAIL): for a queued task whose mission is `completed|failed|cancelled|expired`,
the handler claims the task (`update aios_tasks`), calls the model once, and writes a model-run row. Desired: 409, zero writes, zero model calls.

Not demonstrated (stub limit): that a valid proposal proceeds into tool execution under a cancelled mission. The code path suggests it
would; it needs a database-backed test to confirm.

## F2: lost mission-start is ignored (race form of F1)

L240 requests `.select("id")` on the guarded `queued -> running` mission update but inspects only `error`. When the mission was
cancelled between claim and mission-start, zero rows match, no error is raised, and execution continues.
Observed (probe `gaps/mission_start_race.gap.ts`): model calls = 1, wanted 0. The certified test for this window proves only that the
mission row is not resurrected; it does not (and must not be read to) prove the stale execution stops.

## Which layer owns the invariant: both

- **Database.** Static reading: `private.aios_task_status_guard` (latest definition: `20260825123324_aios_execution_kernel_completion_guards.sql`)
  validates per-row transitions only and references neither `mission_id` nor `aios_missions`. `private.aios_mission_status_guard` blocks
  terminal -> anything on the mission row (so DB-level mission resurrection is already prevented), but nothing makes a task's
  `queued|approved -> running` conditional on its parent mission. This cross-row invariant is enforced **at neither layer today**.
  Only the database can close the check-then-claim race: a handler read followed by a claim always leaves a window.
- **Handler.** Needed regardless, for cheap early refusal before token spend, and to act on the zero-row result at L240 (F2).
- Therefore: handler check + zero-row handling for fast, clear failure; database enforcement (or cascade-cancel of tasks when a mission
  turns terminal) as the actual guarantee. A handler-only fix would leave a TOCTOU window.

## Not done, by directive
No edit to `execute-task/index.ts`, migrations, triggers; no deployment. Remediation needs separate Human Director authorization and a
database-backed regression test (local Supabase stack, as in CI job `migrations-and-sql-tests`) to prove the DB layer, which this
test double cannot.

## Observation (not asserted as a defect)
`launch-mission` compensation is guarded by `status = queued`. When a concurrent cancellation wins, the guarded update matches zero rows
with no error, so by code reading the audit event still records `compensated: true` although the canceller's state stands. The mission is
correctly left cancelled; whether `compensated` should instead be false is a product decision. No test asserts either value.


## Agent 004 closure update (2026-11-11)

The original handler gap is addressed on the execution-authority stack: the handler reads the parent mission before task claim, the database claim gate rejects a task whose mission became terminal after that read, and the handler checks the affected-row result of the mission-start compare-and-set. A lost mission-start update triggers task + mission authority revalidation and stops before model use. The handler also revalidates after model planning and immediately before kernel authorization.

Closure evidence is still conditional on the required PR #32 CI run: terminal mission and mission-start race probes must pass; the behavioral suite and mutation controls must remain green; and the real-Postgres mission/task race job must pass on the same PR-head SHA. This note is an implementation status update, not Agent 003 certification.
