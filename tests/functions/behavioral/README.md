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
| Cancellation races (task claim, mission start, failure recording, launch-mission compensation) | `terminal_and_race_test.ts` (races simulated with `world.onOp`) |
| Terminal missions on the ordinary failure paths (model HTTP failure, mission-start DB error), canceller's rows preserved byte-for-byte | `terminal_and_race_test.ts` (second half, "Added by the terminal-state / cancellation-race expansion") |
| Harness can detect regressions | `run_mutants.py` (23 mutants + unmodified control; JSON records each exact source transformation) |

## Terminal-mission and mission-start race closure probes

Two required regression probes live in `gaps/` (`terminal_mission.gap.ts`, `mission_start_race.gap.ts`). They verify early rejection of terminal parent missions and stopping when the mission-start compare-and-set loses to cancellation. The database claim trigger and terminal cascade remain authoritative; real-Postgres race evidence is required in addition to these handler tests.

`gaps/terminal_mission.gap.ts` asserts the desired invariant that a task under a `completed`/`failed`/`cancelled`/`expired`
mission is refused before any claim or model call. It FAILS against the current functions: `execute-task` guards its mission
*updates* but never reads mission status first, and neither the task status-guard trigger nor `aios_kernel_authorize_invocation`
mentions mission status. It is deliberately not named `*_test.ts` so the certified run does not collect it. Run it with
`node --no-warnings tests/functions/behavioral/node/run.mjs --gaps`. CI runs it informationally and uploads the output.

## CI

`.github/workflows/ci.yml` job `functions-behavioral` runs, under the pinned Deno version: the suite, the suite again with `--no-remote`
(proves no remote/network dependency), the O1-O7 invariant guard, the mutation checks, and the terminal-mission / mission-start race closure probes as required checks.
It uploads `behavioral-evidence` (identity incl. PR head SHA + functions tree + Deno version, behavioral.txt, noremote.txt,
invariants.txt, mutation.txt, mutants.json, gaps.txt).

## What this does NOT establish

The Supabase stub is a behavioral test double, not PostgreSQL. It verifies operation order and handler responses. It cannot
establish real transaction atomicity, trigger behaviour, RLS enforcement, or production concurrency. "One INSERT statement"
is asserted at the call site; whether Postgres makes that statement atomic is a separate gate.
Also out of scope here: the registered-tool execution path of `execute-task` (the stub does not model
`.limit/.or/.gte/.lte/.order` and throws if they are reached), `invoke-tool`, and `review-approval`.

Also not covered: the success / task-completion path of `execute-task` (it goes through the registered-tool path the stub does not
model), so the guards on `completed` task/mission writes (`.eq("status","running")`) are not exercised by any test or mutant here.
