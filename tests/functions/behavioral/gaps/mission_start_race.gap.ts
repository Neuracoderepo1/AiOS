// Mission-start race closure regression. Kept as a separate required CI probe for explicit evidence.
//
// Desired invariant: if the parent mission is cancelled in the window between this execution's task claim and its mission
// start, the execution must STOP: no model call (token spend) and no tool path.
//
// The handler checks the affected-row result. If the queued -> running CAS loses, it revalidates task + mission authority
// and returns 409 before model use. The fake DB models the interleaving; real lock/cascade semantics are separately tested
// against PostgreSQL in the migration CI job.
// Run with:  deno test --import-map=tests/functions/behavioral/import_map.json --allow-env --allow-read tests/functions/behavioral/gaps/mission_start_race.gap.ts
import { call, eq, executeTables, fresh, model, world } from "../harness.ts";

function arm() {
  fresh(executeTables());
  model.text = "not a json object";
  world.onOp = (op) => {
    if (op.table === "aios_missions" && op.mode === "update" && op.patch?.status === "running") {
      world.tables.aios_missions[0].status = "cancelled";
    }
  };
}

Deno.test("GAP: execute-task makes NO model call when its mission is cancelled between task claim and mission start", async () => {
  arm();
  const r = await call("execute-task", { task_id: "task-1" });
  eq(r.status, 409, "lost mission-start authority is rejected");
  eq(world.tables.aios_missions[0].status, "cancelled", "mission remains cancelled");
  eq(model.calls, 0, "model calls after the mission was cancelled");
});

// The fake client does not implement the PostgreSQL terminal cascade; the real-Postgres mission/task race suite verifies
// that the live task is terminalized when the mission cancellation wins.
