// GAP PROBE (not part of the certified suite; deliberately not named *_test.ts so `deno test <dir>` does not collect it).
//
// Desired invariant: if the parent mission is cancelled in the window between this execution's task claim and its mission
// start, the execution must STOP: no model call (token spend) and no tool path.
//
// Why this is a probe: execute-task requests `.select("id")` on the guarded mission-start update (queued -> running) but only
// inspects the error; the returned row set (empty when the mission is no longer 'queued') is never examined, so execution
// proceeds to the model call and, on a valid proposal, to tool execution under a cancelled mission. The certified test
// "mission CANCELLED between task claim and mission start is not resurrected" proves only that the mission ROW is protected,
// not that the stale execution stops. That is the finding.
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
  await call("execute-task", { task_id: "task-1" });
  eq(model.calls, 0, "model calls after the mission was cancelled");
});

// NOT probed here: whether the claimed task is stranded 'running' after a lost mission start. That depends on the registered-tool
// path, which the stub does not model (see README, "What this does NOT establish"); a probe there would be decided by the stub, not
// by the handler. It belongs in a database-backed test (see the finding's remediation section).
