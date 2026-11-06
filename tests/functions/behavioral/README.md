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
| Harness can detect regressions | `run_mutants.py` (17 mutants + unmodified control) |

## What this does NOT establish

The Supabase stub is a behavioral test double, not PostgreSQL. It verifies operation order and handler responses. It cannot
establish real transaction atomicity, trigger behaviour, RLS enforcement, or production concurrency. "One INSERT statement"
is asserted at the call site; whether Postgres makes that statement atomic is a separate gate.
Also out of scope here: the registered-tool execution path of `execute-task` (the stub does not model
`.limit/.or/.gte/.lte/.order` and throws if they are reached), `invoke-tool`, and `review-approval`.
