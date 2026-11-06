// Terminal-state and cancellation-race behavior. Terminal statuses (per the DB status-guard triggers): completed, failed,
// cancelled, expired. A terminal row must never be resurrected or overwritten by a handler that lost a race.
//
// Races are simulated with world.onOp, which mutates the fake database "between" the handler's read and its next write.
// The stub is not PostgreSQL: these tests prove the handlers' write GUARDS (compare-and-set filters, error handling), not the
// database's own transition triggers.
import { assert, call, eq, executeTables, fresh, LAUNCH_BODY, launchTables, model, okTask, planJson, world, writeLog } from "./harness.ts";

const BODY = { task_id: "task-1" };
const task = () => world.tables.aios_tasks.find((t) => t.id === "task-1");
const mission = () => world.tables.aios_missions.find((m) => m.id === "mission-1");
const TERMINAL = ["completed", "failed", "cancelled", "expired"];

// ---- execute-task: task already terminal / in flight --------------------------------------------------------------------

for (const status of [...TERMINAL, "running", "blocked_pending_approval"]) {
  Deno.test(`execute-task: task already '${status}' without an idempotency key -> 409, no writes, no model call`, async () => {
    fresh(executeTables({ task: { status } }));
    const r = await call("execute-task", BODY);
    eq(r.status, 409, "status");
    eq(writeLog(), [], "no writes");
    eq(model.calls, 0, "no model call");
    eq(task().status, status, "task status unchanged");
  });
}

// ---- execute-task: cancellation races on the task ------------------------------------------------------------------------

Deno.test("execute-task: task CANCELLED between read and claim -> 409, stays cancelled, mission untouched, no model call", async () => {
  fresh(executeTables());
  world.onOp = (op) => {
    if (op.table === "aios_tasks" && op.mode === "update" && op.patch?.status === "running") task().status = "cancelled";
  };
  const r = await call("execute-task", BODY);
  eq(r.status, 409, "status");
  eq(task().status, "cancelled", "the cancellation is not overwritten by 'running'");
  assert(!world.ops.some((o) => o.table === "aios_missions"), "mission never touched");
  eq(model.calls, 0, "no model call");
});

Deno.test("execute-task: task cancelled WHILE running is never overwritten to 'failed' by this execution", async () => {
  fresh(executeTables());
  model.text = "not a json object"; // forces the failure path after the claim
  world.onOp = (op) => {
    if (op.table === "aios_missions" && op.mode === "update" && op.patch?.status === "running") task().status = "cancelled";
  };
  await call("execute-task", BODY);
  eq(task().status, "cancelled", "failure recording is guarded by status = running");
});

// ---- execute-task: terminal / cancelled missions -------------------------------------------------------------------------

for (const status of TERMINAL) {
  Deno.test(`execute-task: a '${status}' mission row is never modified by an execution (no resurrection, no overwrite)`, async () => {
    fresh(executeTables({ mission: { status, started_at: "2026-01-01T00:00:00Z", completed_at: "2026-01-02T00:00:00Z" } }));
    model.text = "not a json object";
    const before = structuredClone(mission());
    await call("execute-task", BODY);
    eq(mission(), before, `${status} mission row is byte-for-byte unchanged`);
  });
}

Deno.test("execute-task: mission CANCELLED between task claim and mission start is not resurrected to 'running'", async () => {
  fresh(executeTables());
  model.text = "not a json object";
  world.onOp = (op) => {
    if (op.table === "aios_missions" && op.mode === "update" && op.patch?.status === "running") mission().status = "cancelled";
  };
  await call("execute-task", BODY);
  eq(mission().status, "cancelled", "mission stays cancelled");
  assert(mission().started_at === undefined, "no started_at written onto a cancelled mission");
});

Deno.test("execute-task: mission CANCELLED while the task runs is not overwritten to 'failed' when the task fails", async () => {
  fresh(executeTables());
  model.text = "not a json object";
  world.onOp = (op) => {
    if (op.table === "aios_tasks" && op.mode === "update" && op.patch?.status === "failed") mission().status = "cancelled";
  };
  await call("execute-task", BODY);
  eq(task().status, "failed", "the task failure is still recorded and diagnosable");
  eq(task().failed_stage, "proposal_validation", "failed_stage recorded");
  eq(mission().status, "cancelled", "the cancellation wins; mission is not rewritten to 'failed'");
});

// ---- launch-mission: cancellation race during compensation ---------------------------------------------------------------

Deno.test("launch-mission: mission CANCELLED concurrently before compensation keeps the canceller's metadata", async () => {
  fresh(launchTables());
  model.text = planJson([okTask("low"), okTask("high")]);
  world.fail["aios_tasks:insert"] = "boom";
  world.onOp = (op) => {
    if (op.table === "aios_tasks" && op.mode === "insert") {
      const m = world.tables.aios_missions[0];
      m.status = "cancelled";
      m.metadata = { cancelled_by: "ops" };
    }
  };
  const r = await call("launch-mission", LAUNCH_BODY);
  eq(r.status, 500, "status");
  const m = world.tables.aios_missions[0];
  eq(m.status, "cancelled", "still cancelled");
  eq(m.metadata, { cancelled_by: "ops" }, "compensation (guarded by status = queued) did not overwrite the canceller's metadata");
  assert((world.tables.aios_audit_events ?? []).some((a) => a.event_type === "mission_creation_failed"), "the failure is still audited");
  assert(!(world.tables.aios_tasks ?? []).length, "no task rows");
});
