// Terminal-mission closure regression. Kept as a separate required CI probe for explicit evidence.
//
// Desired invariant: a task whose mission is already TERMINAL (completed/failed/cancelled/expired) must not be claimed or
// executed; no model call (token spend) and no tool invocation may happen on behalf of a cancelled mission.
//
// The handler performs an early read-only parent-mission check; the database claim trigger is the authoritative race fence.
// This test verifies the handler's early rejection. PostgreSQL race enforcement is covered by the real-Postgres suite.
// Run with:  node --no-warnings tests/functions/behavioral/node/run.mjs --gaps
//       or:  deno test --import-map=tests/functions/behavioral/import_map.json --allow-env --allow-read tests/functions/behavioral/gaps/terminal_mission.gap.ts
import { call, eq, executeTables, fresh, model, world, writeLog } from "../harness.ts";

for (const status of ["completed", "failed", "cancelled", "expired"]) {
  Deno.test(`GAP: execute-task must refuse a queued task whose mission is '${status}' (no claim, no model call)`, async () => {
    fresh(executeTables({ mission: { status } }));
    model.text = "not a json object";
    const r = await call("execute-task", { task_id: "task-1" });
    eq([r.status, writeLog(), model.calls], [409, [], 0], "expected 409, zero writes, zero model calls");
    eq(world.tables.aios_tasks[0].status, "queued", "task left queued");
  });
}
