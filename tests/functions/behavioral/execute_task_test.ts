// Behavioral tests for supabase/functions/execute-task covering authentication, claiming, model planning and failure paths.
// The registered support.search_tickets completion/cancellation boundary is exercised separately in execute_task_completion_race_test.ts.
import { assert, call, eq, errors, executeTables, fresh, model, ORG, world, writeLog, writes } from "./harness.ts";

const FN = "execute-task";
const BODY = { task_id: "task-1" };
const task = () => world.tables.aios_tasks.find((t) => t.id === "task-1");
const mission = () => world.tables.aios_missions.find((m) => m.id === "mission-1");

// ---- authentication before API-key validation ---------------------------------------------------------------------------

Deno.test("execute-task: missing Authorization -> 401, nothing touched", async () => {
  fresh(executeTables(), { anthropicKey: null });
  const r = await call(FN, BODY, {});
  eq(r.status, 401, "status");
  eq(world.ops.length, 0, "no database operations");
});

Deno.test("execute-task: authentication happens BEFORE API-key validation (invalid session + no key -> 401, not 503)", async () => {
  fresh(executeTables(), { anthropicKey: null });
  world.validSession = false;
  const r = await call(FN, BODY);
  eq(r.status, 401, "must be 401, not the 503 for a missing key");
  eq(world.ops.length, 0, "no database operations");
  eq(model.calls, 0, "no model calls");
});

Deno.test("execute-task: org authorization happens BEFORE API-key validation (non-member + no key -> 403, not 503)", async () => {
  fresh(executeTables(), { anthropicKey: null });
  world.isMember = false;
  const r = await call(FN, BODY);
  eq(r.status, 403, "status");
  eq(writes().length, 0, "no writes");
});

Deno.test("execute-task: request/resource validation happens BEFORE API-key validation", async () => {
  fresh(executeTables(), { anthropicKey: null });
  eq((await call(FN, "{not json")).status, 400, "bad JSON");
  eq((await call(FN, {})).status, 400, "missing task_id");
  eq((await call(FN, { task_id: "nope" })).status, 404, "unknown task");
  world.tables.aios_tasks[0].assigned_agent_id = null;
  eq((await call(FN, BODY)).status, 422, "unassigned task");
  eq(writes().length, 0, "no writes across any of these rejections");
});

Deno.test("execute-task: suspended agent -> 403 before API-key validation, no writes", async () => {
  fresh(executeTables(), { anthropicKey: null });
  world.tables.aios_agents[0].status = "suspended";
  const r = await call(FN, BODY);
  eq(r.status, 403, "status");
  eq(writes().length, 0, "no writes");
});

Deno.test("execute-task: valid caller, executable task, no API key -> 503 with the task left untouched", async () => {
  fresh(executeTables(), { anthropicKey: null });
  const r = await call(FN, BODY);
  eq(r.status, 503, "status");
  eq(writes().length, 0, "no writes: task and mission untouched");
  eq(task().status, "queued", "task still queued");
  eq(mission().status, "queued", "mission still queued");
});

// ---- idempotent replay without an Anthropic key -------------------------------------------------------------------------

const inv = (over: Record<string, unknown> = {}) => ({
  id: "inv-1", organization_id: ORG, idempotency_key: "k1", task_id: "task-1", status: "succeeded",
  approval_id: null, result: { count: 2 }, error_code: null, error_message: null, ...over,
});
function replayWorld(taskStatus: string, invocation: Record<string, unknown>) {
  const t = executeTables({ task: { status: taskStatus, result: { done: true } }, mission: { status: "completed" } });
  t.aios_tool_invocations = [inv(invocation)];
  return t;
}

Deno.test("execute-task: idempotent replay of a succeeded invocation works WITHOUT an API key, read-only", async () => {
  fresh(replayWorld("completed", {}), { anthropicKey: null });
  const r = await call(FN, { task_id: "task-1", idempotency_key: "k1" });
  eq(r.status, 200, "status");
  eq(r.json.idempotent_replay, true, "idempotent_replay flag");
  eq(r.json.invocation_id, "inv-1", "invocation id");
  eq(r.json.result, { done: true }, "recorded task result returned");
  eq(world.ops.every((o) => o.mode === "select"), true, "every operation is a read");
  eq(writes().length, 0, "no writes");
  eq(model.calls, 0, "no model calls");
});

Deno.test("execute-task: replay of a requires_approval invocation -> 202 without a key, read-only", async () => {
  fresh(replayWorld("blocked_pending_approval", { status: "requires_approval", approval_id: "appr-1" }), { anthropicKey: null });
  const r = await call(FN, { task_id: "task-1", idempotency_key: "k1" });
  eq(r.status, 202, "status");
  eq(r.json.approval_id, "appr-1", "approval id");
  eq(writes().length, 0, "no writes");
});

Deno.test("execute-task: replay of an executing invocation -> 202 without a key, read-only", async () => {
  fresh(replayWorld("running", { status: "executing" }), { anthropicKey: null });
  const r = await call(FN, { task_id: "task-1", idempotency_key: "k1" });
  eq(r.status, 202, "status");
  eq(writes().length, 0, "no writes");
});

Deno.test("execute-task: replay of a failed invocation -> 409 with its recorded error code, read-only", async () => {
  fresh(replayWorld("failed", { status: "failed", error_code: "TOOL_EXECUTION_FAILED", error_message: "x" }), { anthropicKey: null });
  const r = await call(FN, { task_id: "task-1", idempotency_key: "k1" });
  eq(r.status, 409, "status");
  eq(r.json.error_code, "TOOL_EXECUTION_FAILED", "error code");
  eq(r.json.idempotent_replay, true, "flag");
  eq(writes().length, 0, "no writes");
});

Deno.test("execute-task: a key bound to a DIFFERENT task is not replayed (plain 409, no idempotent_replay)", async () => {
  fresh(replayWorld("completed", { task_id: "task-OTHER" }), { anthropicKey: null });
  const r = await call(FN, { task_id: "task-1", idempotency_key: "k1" });
  eq(r.status, 409, "status");
  assert(!r.json.idempotent_replay, "must not leak another task's invocation");
  eq(writes().length, 0, "no writes");
});

Deno.test("execute-task: a replay key from another organization is not honoured", async () => {
  fresh(replayWorld("completed", { organization_id: "org-OTHER" }), { anthropicKey: null });
  const r = await call(FN, { task_id: "task-1", idempotency_key: "k1" });
  eq(r.status, 409, "status");
  assert(!r.json.idempotent_replay, "cross-organization replay must not happen");
});

Deno.test("execute-task: non-executable task WITHOUT an idempotency key -> plain 409, never replayed", async () => {
  fresh(replayWorld("completed", {}), { anthropicKey: null });
  const r = await call(FN, { task_id: "task-1" });
  eq(r.status, 409, "status");
  assert(!r.json.idempotent_replay, "no replay without a key");
});

// ---- task claiming before mission startup -------------------------------------------------------------------------------

Deno.test("execute-task: the task is claimed BEFORE the mission is started, and both happen before any model call", async () => {
  fresh(executeTables());
  const seen: Array<[string, string, number]> = [];
  world.onOp = (op) => { if (op.mode !== "select") seen.push([op.table, String(op.patch?.status), model.calls]); };
  model.text = "this is not a JSON object";
  await call(FN, BODY);
  assert(seen.length >= 2, `at least two writes happened (saw ${JSON.stringify(seen)})`);
  eq(seen[0].slice(0, 2), ["aios_tasks", "running"], "first write claims the task");
  eq(seen[1].slice(0, 2), ["aios_missions", "running"], "second write starts the mission");
  eq(seen[0][2], 0, "no model call before the task claim");
  eq(seen[1][2], 0, "no model call before the mission start");
});

Deno.test("execute-task: the claim is a compare-and-set on the status that was read", async () => {
  fresh(executeTables({ task: { status: "approved" } }));
  model.text = "not json";
  await call(FN, BODY);
  const claim = world.ops.find((o) => o.table === "aios_tasks" && o.mode === "update");
  assert(claim, "claim happened");
  assert(claim.filters.some(([op, c, v]) => op === "eq" && c === "id" && v === "task-1"), "filtered by id");
  assert(claim.filters.some(([op, c, v]) => op === "eq" && c === "status" && v === "approved"), "filtered by the status read (approved)");
});

Deno.test("execute-task: a LOST claim -> 409, mission untouched, no model call, winner's task is not failed", async () => {
  fresh(executeTables());
  world.onOp = (op) => {
    // Another execution wins the race between our read and our claim.
    if (op.table === "aios_tasks" && op.mode === "update" && op.patch?.status === "running") task().status = "running";
  };
  const r = await call(FN, BODY);
  eq(r.status, 409, "status");
  eq(r.json.error, "Task was already claimed by another execution", "error");
  assert(!world.ops.some((o) => o.table === "aios_missions" && o.mode !== "select"), "loser performs no mission writes");
  eq(model.calls, 0, "no model call by the loser");
  eq(task().status, "running", "the winner's task is left running, not failed");
  eq(writeLog(), ["update aios_tasks"], "the only write is the failed claim attempt");
});

Deno.test("execute-task: a claim DB error -> 500, mission untouched, no model call", async () => {
  fresh(executeTables());
  world.fail["aios_tasks:update"] = "db down";
  const r = await call(FN, BODY);
  eq(r.status, 500, "status");
  eq(r.json.error, "Failed to start task", "error");
  assert(!world.ops.some((o) => o.table === "aios_missions" && o.mode !== "select"), "claim failure performs no mission writes");
  eq(model.calls, 0, "no model call");
});

Deno.test("execute-task: an already-running mission keeps its original started_at", async () => {
  fresh(executeTables({ mission: { status: "running", started_at: "2026-01-01T00:00:00Z" } }));
  model.text = "not json";
  await call(FN, BODY);
  eq(mission().started_at, "2026-01-01T00:00:00Z", "started_at not overwritten");
});

// ---- mission-start failure leaves a diagnosable failed task --------------------------------------------------------------

Deno.test("execute-task: mission-start failure -> 500, task FAILED with stage + error, no model call", async () => {
  fresh(executeTables());
  world.fail["aios_missions:update"] = "mission table locked";
  const r = await call(FN, BODY);
  eq(r.status, 500, "status");
  eq(r.json.error, "Failed to start mission", "error");
  eq(r.json.tool_executed, false, "tool_executed flag");
  const t = task();
  eq(t.status, "failed", "task is terminal, not stranded in 'running'");
  eq(t.failed_stage, "mission_start", "failed_stage");
  assert(String(t.last_error).includes("mission table locked"), `last_error carries the cause (got ${JSON.stringify(t.last_error)})`);
  eq(t.result.error, "mission_start_failed", "result.error");
  assert(String(t.result.detail).includes("mission table locked"), "result.detail carries the cause");
  eq(t.result.tool_executed, false, "result.tool_executed");
  assert(typeof t.completed_at === "string", "completed_at set");
  eq(model.calls, 0, "no model call after a failed mission start");
  eq(mission().status, "queued", "mission never moved to running");
  assert(errors.some((e) => e.includes("failed to record mission failure")), `the unrecordable mission failure is logged (errors: ${JSON.stringify(errors)})`);
});

Deno.test("execute-task: model failure after the claim -> task AND mission end 'failed' with stage model_proposal", async () => {
  fresh(executeTables());
  model.status = 500;
  const r = await call(FN, BODY);
  eq(r.status, 502, "status");
  eq(task().status, "failed", "task failed");
  eq(task().failed_stage, "model_proposal", "failed_stage");
  eq(mission().status, "failed", "mission failed, not left running");
  eq(model.calls, 1, "exactly one model call");
});

Deno.test("execute-task: invalid tool proposal after the claim -> 422, task and mission end 'failed'", async () => {
  fresh(executeTables());
  model.text = "no json here";
  const r = await call(FN, BODY);
  eq(r.status, 422, "status");
  eq(task().status, "failed", "task failed");
  eq(task().failed_stage, "proposal_validation", "failed_stage");
  eq(mission().status, "failed", "mission failed");
});
