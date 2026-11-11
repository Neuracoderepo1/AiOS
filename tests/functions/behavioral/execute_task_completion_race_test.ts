// End-to-end handler regression for cancellation after the registered tool has executed and its result is sealed,
// but before the task's conditional completion write. The fake client models the handler boundary only; PostgreSQL cascade
// and lock behavior remain covered by the real-Postgres concurrency suites.
import { call, eq, executeTables, fresh, model, world } from "./harness.ts";

Deno.test("execute-task: cancellation during final analysis is detected before task completion", async () => {
  const tables = executeTables();
  tables.aios_tools = [{
    id: "tool-1", tool_key: "support.search_tickets", name: "Search support tickets", version: 1,
    risk_level: "low", input_schema: { type: "object" }, output_schema: { type: "object" },
    handler: "support.search_tickets", status: "active", is_enabled: true,
    requires_approval: false, idempotency_required: false, timeout_ms: 5000,
  }];
  tables.aios_demo_support_tickets = [{
    id: "ticket-1", organization_id: "org-1", category: "billing",
    issue_summary: "A customer reports a duplicate charge", created_at: "2026-01-01T00:00:00Z",
  }];
  fresh(tables);
  const proposal = JSON.stringify({ tool_key: "support.search_tickets", arguments: { limit: 2 } });
  const final = JSON.stringify({ summary: "One billing issue found", findings: [] });
  model.onCall = () => { model.text = model.calls === 1 ? proposal : final; };

  let cancellationFired = false;
  world.onOp = (op) => {
    if (op.table === "aios_tool_invocations" && op.mode === "insert" && op.rows?.[0]) op.rows[0].status = "executing";
    if (op.table === "aios_model_runs" && op.mode === "insert" && op.rows?.[0]?.outcome === "task_analysis" && !cancellationFired) {
      cancellationFired = true;
      Object.assign(world.tables.aios_tasks[0], { status: "cancelled", result: { cancelled_by: "ops" }, completed_at: "2026-01-02T00:00:00Z" });
      Object.assign(world.tables.aios_missions[0], { status: "cancelled", metadata: { cancelled_by: "ops" }, completed_at: "2026-01-02T00:00:00Z" });
    }
  };

  const r = await call("execute-task", { task_id: "task-1" });
  eq(cancellationFired, true, "cancellation barrier fired after final analysis response");
  eq(model.calls, 2, "planning and final analysis each ran once");
  eq(r.status, 409, "post-analysis authority revalidation rejects completion");
  eq(r.json.tool_executed, true, "response reports the already-executed tool");
  eq(r.json.tool_result_preserved, true, "response reports the sealed result");
  eq(world.tables.aios_tasks[0].status, "cancelled", "task remains cancelled");
  eq(world.tables.aios_missions[0].status, "cancelled", "mission remains cancelled");
  eq(world.tables.aios_tool_invocations[0].status, "succeeded", "sealed invocation remains succeeded");
  eq(world.ops.filter((op) => op.table === "aios_tasks" && op.mode === "update" && op.patch?.status === "completed").length, 0, "completion CAS is not attempted after post-analysis authority loss");
  eq(world.rpcs.some((rpc) => rpc.name === "aios_record_evaluation"), false, "evaluation is not recorded");
});

Deno.test("execute-task: cancellation wins at the final task-completion CAS and sealed tool result is retained", async () => {
  const tables = executeTables();
  tables.aios_tools = [{
    id: "tool-1", tool_key: "support.search_tickets", name: "Search support tickets", version: 1,
    risk_level: "low", input_schema: { type: "object" }, output_schema: { type: "object" },
    handler: "support.search_tickets", status: "active", is_enabled: true,
    requires_approval: false, idempotency_required: false, timeout_ms: 5000,
  }];
  tables.aios_demo_support_tickets = [{
    id: "ticket-1", organization_id: "org-1", category: "billing",
    issue_summary: "A customer reports a duplicate charge", created_at: "2026-01-01T00:00:00Z",
  }];
  fresh(tables);
  const proposal = JSON.stringify({ tool_key: "support.search_tickets", arguments: { limit: 2 } });
  const final = JSON.stringify({ summary: "One billing issue found", findings: [] });
  model.onCall = () => { model.text = model.calls === 1 ? proposal : final; };

  let cancellationFired = false;
  world.onOp = (op) => {
    if (op.table === "aios_tool_invocations" && op.mode === "insert" && op.rows?.[0]) op.rows[0].status = "executing";
    if (op.table === "aios_tasks" && op.mode === "update" && op.patch?.status === "completed" && !cancellationFired) {
      cancellationFired = true;
      Object.assign(world.tables.aios_tasks[0], { status: "cancelled", result: { cancelled_by: "ops" }, completed_at: "2026-01-02T00:00:00Z" });
      Object.assign(world.tables.aios_missions[0], { status: "cancelled", metadata: { cancelled_by: "ops" }, completed_at: "2026-01-02T00:00:00Z" });
    }
  };

  const r = await call("execute-task", { task_id: "task-1" });
  eq(cancellationFired, true, "cancellation barrier fired at the task completion update");
  eq(model.calls, 2, "planning and final analysis each ran once");
  eq(r.status, 409, "zero-row completion CAS returns 409");
  eq(r.json.tool_executed, true, "response reports the already-executed tool");
  eq(r.json.tool_result_preserved, true, "response reports the sealed result");
  eq(world.tables.aios_tasks[0].status, "cancelled", "task remains cancelled");
  eq(world.tables.aios_missions[0].status, "cancelled", "mission remains cancelled");
  eq(world.tables.aios_tool_invocations[0].status, "succeeded", "sealed invocation remains succeeded");
  eq(world.tables.aios_tool_invocations[0].result.count, 1, "sealed result is retained");
  eq(world.ops.filter((op) => op.table === "aios_tasks" && op.mode === "update" && op.patch?.status === "completed").length, 1, "completion CAS was attempted once");
  eq(world.rpcs.some((rpc) => rpc.name === "aios_record_evaluation"), false, "evaluation is not recorded");
});

Deno.test("execute-task: registered tool success completes task and mission and records evaluation", async () => {
  const tables = executeTables();
  tables.aios_tools = [{
    id: "tool-1",
    tool_key: "support.search_tickets",
    name: "Search support tickets",
    version: 1,
    risk_level: "low",
    input_schema: { type: "object" },
    output_schema: { type: "object" },
    handler: "support.search_tickets",
    status: "active",
    is_enabled: true,
    requires_approval: false,
    idempotency_required: false,
    timeout_ms: 5000,
  }];
  tables.aios_demo_support_tickets = [{
    id: "ticket-1",
    organization_id: "org-1",
    category: "billing",
    issue_summary: "A customer reports a duplicate charge",
    created_at: "2026-01-01T00:00:00Z",
  }];
  fresh(tables);

  const proposal = JSON.stringify({ tool_key: "support.search_tickets", arguments: { limit: 2 } });
  const final = JSON.stringify({ summary: "One billing issue found", findings: [] });
  model.onCall = () => { model.text = model.calls === 1 ? proposal : final; };
  world.onOp = (op) => {
    if (op.table === "aios_tool_invocations" && op.mode === "insert" && op.rows?.[0]) {
      op.rows[0].status = "executing";
    }
  };

  const r = await call("execute-task", { task_id: "task-1" });
  eq(r.status, 200, "successful tool execution response");
  eq(model.calls, 2, "planning and final analysis each ran once");
  eq(world.tables.aios_tasks[0].status, "completed", "task reaches completed");
  eq(world.tables.aios_missions[0].status, "completed", "single-task mission reaches completed");
  eq(world.tables.aios_tool_invocations.length, 1, "exactly one invocation exists");
  eq(world.tables.aios_tool_invocations[0].status, "succeeded", "invocation is sealed succeeded");
  eq(world.tables.aios_tool_invocations[0].result.count, 1, "registered tool result is persisted");
  eq(world.rpcs.some((rpc) => rpc.name === "aios_record_evaluation"), true, "evaluation is recorded after successful completion");
});

Deno.test("execute-task: cancellation after tool result sealing prevents task completion and preserves invocation result", async () => {
  const tables = executeTables();
  tables.aios_tools = [{
    id: "tool-1",
    tool_key: "support.search_tickets",
    name: "Search support tickets",
    version: 1,
    risk_level: "low",
    input_schema: { type: "object" },
    output_schema: { type: "object" },
    handler: "support.search_tickets",
    status: "active",
    is_enabled: true,
    requires_approval: false,
    idempotency_required: false,
    timeout_ms: 5000,
  }];
  tables.aios_demo_support_tickets = [{
    id: "ticket-1",
    organization_id: "org-1",
    category: "billing",
    issue_summary: "A customer reports a duplicate charge",
    created_at: "2026-01-01T00:00:00Z",
  }];
  fresh(tables);

  const proposal = JSON.stringify({ tool_key: "support.search_tickets", arguments: { limit: 2 } });
  const final = JSON.stringify({ summary: "One billing issue found", findings: [] });
  model.onCall = () => { model.text = model.calls === 1 ? proposal : final; };

  let cancellationFired = false;
  world.onOp = (op) => {
    if (op.table === "aios_tool_invocations" && op.mode === "insert" && op.rows?.[0]) {
      op.rows[0].status = "executing";
    }
    if (op.table === "aios_tool_invocations" && op.mode === "update" && op.patch?.status === "succeeded" && !cancellationFired) {
      cancellationFired = true;
      Object.assign(world.tables.aios_tasks[0], {
        status: "cancelled",
        result: { cancelled_by: "ops" },
        completed_at: "2026-01-02T00:00:00Z",
        last_error: "cancelled during tool completion",
      });
      Object.assign(world.tables.aios_missions[0], {
        status: "cancelled",
        metadata: { cancelled_by: "ops" },
        completed_at: "2026-01-02T00:00:00Z",
      });
    }
  };

  const r = await call("execute-task", { task_id: "task-1" });
  eq(cancellationFired, true, `cancellation barrier fired after tool success was sealed; response=${JSON.stringify(r)} ops=${JSON.stringify(world.ops.map((op) => ({ table: op.table, mode: op.mode, patch: op.patch })))}`);
  eq(model.calls, 1, "planning ran once; final analysis is skipped after authority loss");
  eq(r.status, 409, "authority loss after tool execution is rejected");
  eq(world.tables.aios_tasks[0].status, "cancelled", "task remains cancelled");
  eq(world.tables.aios_missions[0].status, "cancelled", "mission remains cancelled");
  eq(world.tables.aios_tool_invocations.length, 1, "exactly one invocation exists");
  eq(world.tables.aios_tool_invocations[0].status, "succeeded", "tool result remains sealed as succeeded");
  eq(world.tables.aios_tool_invocations[0].result.count, 1, "sealed tool result is preserved");
  eq(world.ops.filter((op) => op.table === "aios_demo_support_tickets" && op.mode === "select").length, 1, "registered tool ran once");
  eq(world.ops.filter((op) => op.table === "aios_tasks" && op.mode === "update" && op.patch?.status === "completed").length, 0, "completion CAS is not attempted after authority loss");
  eq(world.rpcs.some((rpc) => rpc.name === "aios_record_evaluation"), false, "no evaluation is recorded for a cancelled task");
});
