// Behavioral tests for supabase/functions/launch-mission. Every assertion is about what the handler DID (responses, ordered
// database writes, audit rows), not about what its source text looks like.
import { assert, call, eq, errors, fresh, LAUNCH_BODY, launchTables, model, okTask, ORG, planJson, world, writeLog, writes } from "./harness.ts";

const FN = "launch-mission";
const PLAN3 = planJson([okTask("low"), okTask("medium"), okTask("high")]);

// ---- authentication / authorization ordering ---------------------------------------------------------------------------

Deno.test("launch-mission: missing Authorization -> 401, nothing touched", async () => {
  fresh(launchTables(), { anthropicKey: null });
  const r = await call(FN, LAUNCH_BODY, {});
  eq(r.status, 401, "status");
  eq(world.ops.length, 0, "no database operations at all");
  eq(model.calls, 0, "no model calls");
});

Deno.test("launch-mission: authentication happens BEFORE API-key validation (invalid session + no key -> 401, not 503)", async () => {
  fresh(launchTables(), { anthropicKey: null });
  world.validSession = false;
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 401, "must be 401 Unauthorized, not the 503 for a missing key");
  eq(writes().length, 0, "no writes");
  eq(model.calls, 0, "no model calls");
});

Deno.test("launch-mission: org authorization happens BEFORE API-key validation (non-member + no key -> 403, not 503)", async () => {
  fresh(launchTables(), { anthropicKey: null });
  world.isMember = false;
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 403, "status");
  eq(world.ops.length, 0, "no database operations (not even the agent lookup)");
});

Deno.test("launch-mission: agent eligibility is checked BEFORE API-key validation (no agent + no key -> 422, not 503)", async () => {
  fresh({ aios_agents: [], aios_contracts: [] }, { anthropicKey: null });
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 422, "status");
  eq(writes().length, 0, "no writes");
});

Deno.test("launch-mission: valid caller but no API key on an AI-planned objective -> 503 with zero writes", async () => {
  fresh(launchTables(), { anthropicKey: null });
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 503, "status");
  eq(writes().length, 0, "no writes");
  eq(model.calls, 0, "no model calls");
});

Deno.test("launch-mission: deterministic support objective needs no API key and creates the mission", async () => {
  fresh(launchTables(), { anthropicKey: null });
  const r = await call(FN, { ...LAUNCH_BODY, objective: "Find the top customer support problems" });
  eq(r.status, 201, "status");
  eq(model.calls, 0, "no model calls");
  eq(r.json.tasks.length, 1, "one deterministic task");
  eq(r.json.tasks[0].risk_level, "low", "deterministic task is low risk");
});

// ---- no database writes before planning/validation finish ---------------------------------------------------------------

const PLANNING_FAILURES: Array<[string, (() => void), number]> = [
  ["model network failure", () => { model.throwNetwork = true; }, 502],
  ["model HTTP 500", () => { model.status = 500; }, 502],
  ["model returns non-JSON text", () => { model.text = "I cannot help with that."; }, 422],
  ["model returns empty array (0 tasks)", () => { model.text = "[]"; }, 422],
  ["model returns 4 tasks (over the limit)", () => { model.text = planJson([okTask(), okTask(), okTask(), okTask()]); }, 422],
  ["model returns blank title", () => { model.text = planJson([okTask("low", { title: "   " })]); }, 422],
  ["model returns non-string instructions", () => { model.text = planJson([okTask("low", { instructions: 42 })]); }, 422],
  ["model returns oversized title", () => { model.text = planJson([okTask("low", { title: "x".repeat(201) })]); }, 422],
  ["second task has an invalid risk level (first is fine)", () => { model.text = planJson([okTask("low"), okTask("severe")]); }, 422],
];
for (const [label, arrange, status] of PLANNING_FAILURES) {
  Deno.test(`launch-mission: no database writes when planning fails: ${label} -> ${status}`, async () => {
    fresh(launchTables());
    arrange();
    const r = await call(FN, LAUNCH_BODY);
    eq(r.status, status, "status");
    eq(writeLog(), [], "no database writes of any kind");
    eq(world.tables.aios_missions ?? [], [], "no mission row exists");
    eq(world.tables.aios_tasks ?? [], [], "no task rows exist");
  });
}

Deno.test("launch-mission: success writes in the documented order (mission, tasks, model run, audit)", async () => {
  fresh(launchTables());
  model.text = PLAN3;
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 201, "status");
  eq(writeLog(), ["insert aios_missions", "insert aios_tasks", "insert aios_model_runs", "insert aios_audit_events"], "write order");
  eq(model.calls, 1, "one planning call");
  eq(r.json.tasks.length, 3, "three tasks returned");
});

// ---- invalid model risk levels -> 422, never coerced ---------------------------------------------------------------------

for (const bad of ["critical", "HIGH", "Low", "", " low", "none", null, 3, ["low"], { level: "low" }]) {
  Deno.test(`launch-mission: invalid model risk_level ${JSON.stringify(bad)} -> HTTP 422 and nothing written`, async () => {
    fresh(launchTables());
    model.text = planJson([okTask(bad)]);
    const r = await call(FN, LAUNCH_BODY);
    eq(r.status, 422, "status");
    eq(r.json.error, "Model returned an invalid risk_level", "error message");
    eq(writeLog(), [], "no writes");
  });
}

Deno.test("launch-mission: missing risk_level -> 422 (not defaulted)", async () => {
  fresh(launchTables());
  model.text = planJson([{ title: "T", instructions: "I" }]);
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 422, "status");
  eq(writeLog(), [], "no writes");
});

Deno.test("launch-mission: valid risk levels are persisted verbatim, never rewritten", async () => {
  fresh(launchTables());
  model.text = PLAN3;
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 201, "status");
  eq((world.tables.aios_tasks ?? []).map((t) => t.risk_level), ["low", "medium", "high"], "stored risk levels");
});

// ---- atomic task insertion + mission compensation -----------------------------------------------------------------------

Deno.test("launch-mission: all tasks go in ONE insert statement (all-or-nothing)", async () => {
  fresh(launchTables());
  model.text = PLAN3;
  await call(FN, LAUNCH_BODY);
  const inserts = world.ops.filter((o) => o.table === "aios_tasks" && o.mode === "insert");
  eq(inserts.length, 1, "exactly one task insert statement");
  eq(inserts[0].rows?.length, 3, "carrying all three rows");
});

Deno.test("launch-mission: task insert failure -> 500, mission compensated to 'cancelled' (not deleted), no orphan tasks", async () => {
  fresh(launchTables());
  model.text = PLAN3;
  world.fail["aios_tasks:insert"] = "boom: constraint violated";
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 500, "status");
  eq(r.json.error, "Task creation failed", "error");
  eq(r.json.mission_status, "cancelled", "reported mission status");
  const missions = world.tables.aios_missions ?? [];
  eq(missions.length, 1, "mission row is preserved, not deleted");
  eq(missions[0].status, "cancelled", "stored mission status");
  eq(missions[0].metadata, { creation_failed: true, stage: "task_creation", reason: "boom: constraint violated" }, "mission metadata");
  eq(world.tables.aios_tasks ?? [], [], "no task rows");
  assert(!world.ops.some((o) => o.mode === "delete"), "compensation must never delete");
  assert(!world.ops.some((o) => o.table === "aios_model_runs"), "no model run is recorded for a mission that failed to start");
  assert(!world.ops.some((o) => o.table === "aios_audit_events" && o.rows?.[0]?.event_type === "mission_created"), "no mission_created audit event");
});

Deno.test("launch-mission: compensation only touches a mission that is still 'queued' (guarded update)", async () => {
  fresh(launchTables());
  model.text = PLAN3;
  world.fail["aios_tasks:insert"] = "boom";
  await call(FN, LAUNCH_BODY);
  const upd = world.ops.find((o) => o.table === "aios_missions" && o.mode === "update");
  assert(upd, "a compensating update happened");
  assert(upd.filters.some(([op, c, v]) => op === "eq" && c === "status" && v === "queued"), "update is guarded by status = queued");
});

Deno.test("launch-mission: mission insert failure -> 500 and no tasks are attempted", async () => {
  fresh(launchTables());
  model.text = PLAN3;
  world.fail["aios_missions:insert"] = "db down";
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 500, "status");
  assert(!world.ops.some((o) => o.table === "aios_tasks"), "no task operations after a failed mission insert");
});

// ---- mission_creation_failed audit metadata + compensation errors --------------------------------------------------------

Deno.test("launch-mission: mission_creation_failed audit event records stage, reason and compensated=true", async () => {
  fresh(launchTables());
  model.text = PLAN3;
  world.fail["aios_tasks:insert"] = "boom: constraint violated";
  const r = await call(FN, LAUNCH_BODY);
  const audits = (world.tables.aios_audit_events ?? []).filter((a) => a.event_type === "mission_creation_failed");
  eq(audits.length, 1, "exactly one failure audit event");
  const a = audits[0];
  eq(a.organization_id, ORG, "organization");
  eq(a.actor_user_id, "user-1", "actor");
  eq(a.mission_id, (world.tables.aios_missions ?? [])[0].id, "mission id");
  eq(a.action, "launch_mission", "action");
  eq(a.decision, "deny", "decision");
  eq(a.previous_state, "queued", "previous_state");
  eq(a.new_state, "cancelled", "new_state");
  eq(a.metadata.stage, "task_creation", "metadata.stage");
  eq(a.metadata.reason, "boom: constraint violated", "metadata.reason");
  eq(a.metadata.compensated, true, "metadata.compensated");
  eq(a.metadata.mission_id, r.json.mission_id, "metadata.mission_id");
  assert(!("compensation_error" in a.metadata), "no compensation_error when compensation succeeded");
});

Deno.test("launch-mission: compensation failure is reported, not hidden (mission stays queued, audit says compensated=false)", async () => {
  fresh(launchTables());
  model.text = PLAN3;
  world.fail["aios_tasks:insert"] = "boom";
  world.fail["aios_missions:update"] = "update denied by policy";
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 500, "status");
  eq(r.json.mission_status, "queued", "response reports the mission is still queued");
  eq((world.tables.aios_missions ?? [])[0].status, "queued", "stored status is unchanged");
  const a = (world.tables.aios_audit_events ?? []).find((x) => x.event_type === "mission_creation_failed");
  assert(a, "failure audit event still written");
  eq(a.new_state, "queued", "audit new_state");
  eq(a.metadata.compensated, false, "metadata.compensated");
  eq(a.metadata.compensation_error, "update denied by policy", "metadata.compensation_error");
  eq(a.metadata.reason, "boom", "original reason preserved");
  assert(errors.some((e) => e.includes("compensation failed") && e.includes("update denied by policy")), `compensation failure logged (errors: ${JSON.stringify(errors)})`);
});

Deno.test("launch-mission: audit write failure during compensation is logged and the 500 response still carries the mission id", async () => {
  fresh(launchTables());
  model.text = PLAN3;
  world.fail["aios_tasks:insert"] = "boom";
  world.fail["aios_audit_events:insert"] = "audit table unavailable";
  const r = await call(FN, LAUNCH_BODY);
  eq(r.status, 500, "status");
  assert(typeof r.json.mission_id === "string", "mission_id returned for diagnosis");
  assert(errors.some((e) => e.includes("audit write failed") && e.includes("audit table unavailable")), `audit failure logged (errors: ${JSON.stringify(errors)})`);
});

Deno.test("launch-mission: failure reason is truncated to 500 characters in mission metadata and audit", async () => {
  fresh(launchTables());
  model.text = PLAN3;
  world.fail["aios_tasks:insert"] = "e".repeat(900);
  await call(FN, LAUNCH_BODY);
  eq((world.tables.aios_missions ?? [])[0].metadata.reason.length, 500, "mission metadata reason length");
  const a = (world.tables.aios_audit_events ?? []).find((x) => x.event_type === "mission_creation_failed");
  eq(a.metadata.reason.length, 500, "audit reason length");
});
