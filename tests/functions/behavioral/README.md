# Edge Function behavioral tests

Executes the real `supabase/functions/{execute-task,launch-mission}/index.ts` handlers with a fake Supabase client and a fake
Anthropic endpoint, and asserts on **responses and the ordered database writes** (not source text).

## Run

Deno (the production runtime, used by CI):

    deno test --import-map=tests/functions/behavioral/import_map.json --allow-env --allow-read tests/functions/behavioral/

Node >= 22.18 fallback (no Deno needed; same tests, same import map, a small `Deno` shim in `node/`):

    node --no-warnings tests/functions/behavioral/node/run.mjs [--filter=text]

Negative tests (deliberately break copies of the functions; the suite must notice each one):

    python3 tests/functions/behavioral/run_mutants.py [--runner "<command>"]

`FUNCTIONS_DIR=<dir>` points the suite at a different copy of the functions (used by the mutation runner).

## What is covered

| Requirement | Where |
|---|---|
| Authentication before API-key validation | `*_test.ts` "authentication happens BEFORE API-key validation" (both functions) |
| Idempotent replay without an Anthropic key | `execute_task_test.ts` replay group |
| No database writes before mission planning/validation finish | `launch_mission_test.ts` "no database writes when planning fails" |
| Atomic task insertion failure and mission compensation | `launch_mission_test.ts` "ONE insert statement", "compensated to 'cancelled'" |
| `mission_creation_failed` audit metadata and compensation errors | `launch_mission_test.ts` audit / compensation group |
| Invalid model risk levels -> HTTP 422 | `launch_mission_test.ts` risk-level group |
| Task claiming before mission startup (incl. lost claim) | `execute_task_test.ts` claim group |
| Mission-start failure leaves a diagnosable failed task | `execute_task_test.ts` mission-start group |
| Import map resolves every dependency | `import_map_test.ts` (scans the real sources) |
| Terminal tasks/missions are never resurrected or overwritten | `terminal_and_race_test.ts` |
| Cancellation races (task claim, mission start, model planning, failure recording, launch-mission compensation) | `terminal_and_race_test.ts` (races simulated with `world.onOp` and model-call barriers) |
| Terminal missions are rejected before ordinary failure paths; task/mission canceller rows remain byte-for-byte intact | `terminal_and_race_test.ts` |
| Registered support-tool success and cancellation at three post-tool boundaries | `execute_task_completion_race_test.ts` (success completes task/mission and records evaluation; cancellation after tool sealing, during final analysis, or at the completion CAS preserves the invocation result) |\n| Harness can detect regressions | `run_mutants.py` (23 mutants + unmodified control; JSON records each exact source transformation) |

## Terminal-mission and mission-start race closure probes

Two required regression probes live in `gaps/` (`terminal_mission.gap.ts`, `mission_start_race.gap.ts`). They verify early rejection of terminal parent missions and stopping when the mission-start compare-and-set loses to cancellation. The handler's early read provides a clean 409; the database claim gate and kernel authorization are the authoritative race fences. Both probes run as required CI checks and their output is uploaded.

## CI

`.github/workflows/ci.yml` job `functions-behavioral` runs, under the pinned Deno version: the suite, the suite again with `--no-remote`
(proves no remote/network dependency), the O1-O7 invariant guard, the mutation checks, and the terminal-mission / mission-start race closure probes as required checks.
It uploads `behavioral-evidence` (identity incl. PR head SHA + functions tree + Deno version, behavioral.txt, noremote.txt,
invariants.txt, mutation.txt, mutants.json, gaps.txt).

## What this does NOT establish

The Supabase stub is a behavioral test double, not PostgreSQL. It verifies operation order and handler responses. It cannot
establish real transaction atomicity, trigger behaviour, RLS enforcement, or production concurrency. "One INSERT statement"
is asserted at the call site; whether Postgres makes that statement atomic is a separate gate.

The completion-race test models the registered `support.search_tickets` handler and proves that a cancellation after the
invocation result is sealed prevents the task's conditional completion write and preserves the invocation result. It does
not exercise every registered tool implementation, a live external side effect, or the normal successful completion /
evaluation path. `invoke-tool` and `review-approval` remain out of scope for this Edge Function harness.
