// GAP PROBE (not part of the certified suite; deliberately not named *_test.ts so `deno test <dir>` does not collect it).
//
// Desired invariant: a task whose mission is already TERMINAL (completed/failed/cancelled/expired) must not be claimed or
// executed; no model call (token spend) and no tool invocation may happen on behalf of a cancelled mission.
//
// Why this is a probe and not a certification test: supabase/functions/execute-task only guards its mission UPDATES
// (queued -> running, running -> failed) and never reads the mission's status before claiming the task and calling the model.
// Neither the task status-guard trigger nor aios_kernel_authorize_invocation refers to mission status, and cancelling a mission
// does not cascade to its tasks. These tests therefore FAIL against the current functions; that is the finding.
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
