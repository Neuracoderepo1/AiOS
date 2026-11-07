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

// =====================================================================================================================
// Added by the terminal-state / cancellation-race expansion (Agent 004 directive). Everything above this line is unchanged.
// =====================================================================================================================

const inserts = (...tables: string[]) => world.ops.filter((o) => o.mode === "insert" && tables.includes(o.table));
const assertNoRecordCreation = () => eq(inserts("aios_tasks", "aios_missions").length, 0, "no task or mission rows were created");
const CANCELLER = { status: "cancelled", result: { cancelled_by: "ops" }, completed_at: "2026-01-02T00:00:00Z", last_error: "cancelled by ops" };

// ---- execute-task: terminal missions on the ordinary FAILURE paths (not only the invalid-proposal path) -----------------
// For each terminal mission status and each failure path: the mission row is byte-for-byte unchanged (status, started_at,
// completed_at and metadata all preserved), the claimed task still ends 'failed' with its stage (diagnostics are not lost),
// and no task/mission record is created. This asserts the handler's own guards: the stub would accept an unguarded write.

const FAILURE_PATHS: Array<{ label: string; arm: () => void; stage: string; http: number; modelCalls: number }> = [
  { label: "model HTTP failure", arm: () => { model.status = 500; }, stage: "model_proposal", http: 502, modelCalls: 1 },
  { label: "mission-start database error", arm: () => { world.fail["aios_missions:update"] = "db down"; }, stage: "mission_start", http: 500, modelCalls: 0 },
];

for (const status of TERMINAL) {
  for (const p of FAILURE_PATHS) {
    Deno.test(`execute-task: '${status}' mission row is untouched on the ${p.label} path and the task failure stays diagnosable`, async () => {
      fresh(executeTables({ mission: { status, started_at: "2026-01-01T00:00:00Z", completed_at: "2026-01-02T00:00:00Z", metadata: { closed_by: "ops" } } }));
      p.arm();
      const before = structuredClone(mission());
      const r = await call("execute-task", BODY);
      eq(r.status, p.http, "http status");
      eq(model.calls, p.modelCalls, "model calls");
      eq(mission(), before, `${status} mission row byte-for-byte unchanged (status, started_at, completed_at, metadata)`);
      eq(task().status, "failed", "the claimed task is failed, not stranded");
      eq(task().failed_stage, p.stage, "failed_stage diagnostics recorded");
      assertNoRecordCreation();
    });
  }
}

// ---- execute-task: a canceller's task row is preserved, not just its status ------------------------------------------------

Deno.test("execute-task: a task cancelled while running keeps the canceller's result, timestamps and error byte-for-byte", async () => {
  fresh(executeTables());
  model.text = "not a json object";
  let snapshot: unknown;
  world.onOp = (op) => {
    if (op.table === "aios_missions" && op.mode === "update" && op.patch?.status === "running" && !snapshot) {
      Object.assign(task(), CANCELLER);
      snapshot = structuredClone(task());
    }
  };
  await call("execute-task", BODY);
  assert(snapshot, "the race fired");
  eq(task(), snapshot, "failure recording (guarded by status = running) did not touch the cancelled task row");
  assertNoRecordCreation();
});

// ---- execute-task: cancellation at the exact boundary of each failure write -------------------------------------------------

Deno.test("execute-task: mission CANCELLED at the exact moment of mission-failure recording keeps the canceller's row", async () => {
  fresh(executeTables());
  model.text = "not a json object";
  let snapshot: unknown;
  world.onOp = (op) => {
    if (op.table === "aios_missions" && op.mode === "update" && op.patch?.status === "failed") {
      Object.assign(mission(), { status: "cancelled", metadata: { cancelled_by: "ops" }, completed_at: "2026-01-02T00:00:00Z" });
      snapshot = structuredClone(mission());
    }
  };
  await call("execute-task", BODY);
  assert(snapshot, "the race fired");
  eq(mission(), snapshot, "the guarded mission-failure write matched no row; status, metadata and completed_at are the canceller's");
  eq(task().status, "failed", "the task failure is still recorded");
  eq(task().failed_stage, "proposal_validation", "failure diagnostics remain available");
  assertNoRecordCreation();
});

Deno.test("execute-task: task CANCELLED while the mission-start failure is being recorded is not overwritten to 'failed'", async () => {
  fresh(executeTables());
  world.fail["aios_missions:update"] = "db down";
  let snapshot: unknown;
  world.onOp = (op) => {
    if (op.table === "aios_missions" && op.mode === "update" && !snapshot) {
      Object.assign(task(), CANCELLER);
      snapshot = structuredClone(task());
    }
  };
  const r = await call("execute-task", BODY);
  eq(r.status, 500, "mission-start failure is still reported");
  eq(model.calls, 0, "no model call");
  assert(snapshot, "the race fired");
  eq(task(), snapshot, "task failure recording is guarded by status = running; the cancelled task row is untouched");
  assertNoRecordCreation();
});

// ---- launch-mission: compensation vs a concurrent cancellation ---------------------------------------------------------------

Deno.test("launch-mission: concurrent cancellation + task-insert failure: failure is audited with its reason, no stray rows, status and metadata are the canceller's", async () => {
  fresh(launchTables());
  model.text = planJson([okTask("low"), okTask("high")]);
  world.fail["aios_tasks:insert"] = "boom";
  let snapshot: unknown;
  world.onOp = (op) => {
    if (op.table === "aios_tasks" && op.mode === "insert") {
      Object.assign(world.tables.aios_missions[0], { status: "cancelled", metadata: { cancelled_by: "ops" }, completed_at: "2026-01-02T00:00:00Z" });
      snapshot = structuredClone(world.tables.aios_missions[0]);
    }
  };
  const r = await call("launch-mission", LAUNCH_BODY);
  eq(r.status, 500, "status");
  assert(snapshot, "the race fired");
  eq(world.tables.aios_missions.length, 1, "exactly one mission row");
  eq(world.tables.aios_missions[0], snapshot, "compensation did not overwrite status, metadata or completed_at");
  eq((world.tables.aios_tasks ?? []).length, 0, "no task rows");
  const audits = (world.tables.aios_audit_events ?? []).filter((a) => a.event_type === "mission_creation_failed");
  eq(audits.length, 1, "exactly one failure audit event");
  eq(audits[0].metadata.reason, "boom", "the original failure reason is preserved in the audit");
  eq(audits[0].mission_id, snapshot && (snapshot as { id: string }).id, "audit references the cancelled mission");
});
