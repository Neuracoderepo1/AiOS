import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS_HEADERS } });
}

// The service-role client is created without generated Database types, so its type is exactly what createClient infers for
// this call. Do NOT annotate it as ReturnType<typeof createClient>: createClient is generic, and TypeScript resolves that to
// SupabaseClient<unknown, ..., never, never>, which turns every query result into `never` and rejects the real client.
function createAdminClient(url: string, serviceKey: string) {
  return createClient(url, serviceKey);
}
type AdminClient = ReturnType<typeof createAdminClient>;

// Columns selected from public.aios_demo_support_tickets (all NOT NULL in the schema).
interface SupportTicketRow {
  id: string;
  category: string;
  issue_summary: string;
  created_at: string;
}

function isSupportTicketRow(value: unknown): value is SupportTicketRow {
  if (typeof value !== "object" || value === null) return false;
  const row = value as Record<string, unknown>;
  return typeof row.id === "string" && typeof row.category === "string" &&
    typeof row.issue_summary === "string" && typeof row.created_at === "string";
}

function parseSupportTicketRows(data: unknown): SupportTicketRow[] {
  if (data === null || data === undefined) return [];
  if (!Array.isArray(data)) throw new Error("support.search_tickets returned a non-array result");
  const rows: SupportTicketRow[] = [];
  for (const item of data) {
    if (!isSupportTicketRow(item)) throw new Error("support.search_tickets returned a row with an unexpected shape");
    rows.push(item);
  }
  return rows;
}

async function sha256(value: unknown): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function canonicalJson(v: unknown): string {
  if (Array.isArray(v)) return "[" + v.map(canonicalJson).join(",") + "]";
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    return "{" + Object.keys(o).sort().map((k) => JSON.stringify(k) + ":" + canonicalJson(o[k])).join(",") + "}";
  }
  return JSON.stringify(v === undefined ? null : v);
}

async function callClaude(apiKey: string, model: string, prompt: string, maxTokens = 1200) {
  const started = Date.now();
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model, max_tokens: maxTokens, messages: [{ role: "user", content: prompt }] }),
  });
  const latency_ms = Date.now() - started;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Anthropic API error: ${res.status}`);
  const text = data.content?.find((b: { type: string }) => b.type === "text")?.text;
  if (!text) throw new Error("Model returned no text content");
  return { text, input_tokens: data.usage?.input_tokens ?? 0, output_tokens: data.usage?.output_tokens ?? 0, latency_ms };
}

// Best-effort writes (observability/memory): never block the critical path, but never fail silently either.
async function bestEffort(label: string, op: PromiseLike<{ error: { message: string } | null }>) {
  try {
    const { error } = await op;
    if (error) console.error(`[execute-task] best-effort write failed: ${label}: ${error.message}`);
  } catch (e) {
    console.error(`[execute-task] best-effort write threw: ${label}: ${String(e)}`);
  }
}

function parseJsonObject(text: string) {
  const cleaned = text.replace(/```json|```/g, "").trim();
  const start = cleaned.indexOf("{");
  const end = cleaned.lastIndexOf("}");
  if (start < 0 || end <= start) throw new Error("Model did not return a JSON object");
  return JSON.parse(cleaned.slice(start, end + 1));
}

function typeMatches(value: unknown, type: string): boolean {
  if (type === "object") return typeof value === "object" && value !== null && !Array.isArray(value);
  if (type === "array") return Array.isArray(value);
  if (type === "string") return typeof value === "string";
  if (type === "integer") return typeof value === "number" && Number.isInteger(value);
  if (type === "number") return typeof value === "number" && Number.isFinite(value);
  if (type === "boolean") return typeof value === "boolean";
  if (type === "null") return value === null;
  return true;
}

function validateAgainstSchema(value: unknown, schema: any, path = "arguments"): void {
  if (!schema || typeof schema !== "object") return;
  if (schema.type && !typeMatches(value, schema.type)) throw new Error(`${path} must be ${schema.type}`);
  if (schema.enum && (!Array.isArray(schema.enum) || !schema.enum.some((x: unknown) => JSON.stringify(x) === JSON.stringify(value)))) {
    throw new Error(`${path} is not an allowed value`);
  }
  if (typeof value === "string" && schema.maxLength !== undefined && value.length > schema.maxLength) throw new Error(`${path} exceeds maxLength ${schema.maxLength}`);
  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) throw new Error(`${path} is below minimum ${schema.minimum}`);
    if (schema.maximum !== undefined && value > schema.maximum) throw new Error(`${path} exceeds maximum ${schema.maximum}`);
  }
  if (schema.type === "object" && value && typeof value === "object" && !Array.isArray(value)) {
    const obj = value as Record<string, unknown>;
    for (const required of schema.required ?? []) if (!(required in obj)) throw new Error(`${path}.${required} is required`);
    const properties = schema.properties ?? {};
    if (schema.additionalProperties === false) {
      for (const key of Object.keys(obj)) if (!(key in properties)) throw new Error(`${path}.${key} is not permitted by the tool registry`);
    }
    for (const [key, child] of Object.entries(properties)) if (key in obj) validateAgainstSchema(obj[key], child, `${path}.${key}`);
  }
  if (schema.type === "array" && Array.isArray(value) && schema.items) {
    value.forEach((item, index) => validateAgainstSchema(item, schema.items, `${path}[${index}]`));
  }
}

async function executeRegisteredHandler(handler: string, args: Record<string, unknown>, organizationId: string, admin: AdminClient): Promise<Record<string, unknown>> {
  switch (handler) {
    case "support.search_tickets": {
      const limit = Number(args.limit);
      let q = admin.from("aios_demo_support_tickets").select("id,category,issue_summary,created_at").eq("organization_id", organizationId).limit(limit);
      if (typeof args.query === "string" && args.query.length) {
        const safe = args.query.replace(/[%_,]/g, " ");
        q = q.or(`category.ilike.%${safe}%,issue_summary.ilike.%${safe}%`);
      }
      const filters = (args.filters ?? {}) as Record<string, unknown>;
      if (typeof filters.category === "string") q = q.eq("category", filters.category);
      if (typeof filters.created_after === "string") q = q.gte("created_at", filters.created_after);
      if (typeof filters.created_before === "string") q = q.lte("created_at", filters.created_before);
      const { data: tickets, error } = await q.order("created_at", { ascending: false });
      if (error) throw new Error(`support.search_tickets failed: ${error.message}`);
      const rows = parseSupportTicketRows(tickets);
      const counts: Record<string, number> = {};
      for (const row of rows) counts[row.category] = (counts[row.category] ?? 0) + 1;
      const summary = Object.entries(counts).sort((a, b) => b[1] - a[1]).map(([category, count]) => ({ category, count }));
      return { tickets: rows, count: rows.length, summary };
    }
    default:
      throw new Error(`No executor registered for tool handler ${handler}`);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

  // Order of checks: authenticate -> parse request -> organization authorization -> resource and state validation ->
  // external-service configuration -> first state mutation. Nothing is written before every check above has passed.
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: "Invalid or expired session" }, 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }
  const task_id = body.task_id as string | undefined;
  const requestedIdempotency = body.idempotency_key as string | undefined;
  if (!task_id) return json({ error: "task_id is required" }, 400);

  const admin = createAdminClient(supabaseUrl, serviceKey);

  const { data: task, error: taskError } = await admin.from("aios_tasks").select("id,organization_id,mission_id,assigned_agent_id,title,instructions,status,risk_level,result").eq("id", task_id).maybeSingle();
  if (taskError) return json({ error: "Task lookup failed", detail: taskError.message }, 500);
  if (!task) return json({ error: "Task not found" }, 404);
  const { data: member } = await userClient.rpc("aios_is_org_member", { org_id: task.organization_id });
  if (!member) return json({ error: "You are not a member of this organization" }, 403);
  if (!task.assigned_agent_id) return json({ error: "Task has no assigned agent" }, 422);
  if (!["queued", "approved"].includes(task.status)) {
    // Retry contract: a client that supplied an idempotency key and retries after the task has moved on gets the recorded
    // state of its own invocation back. This path is read-only: it never claims the task, calls a model, or runs a tool.
    if (requestedIdempotency) {
      const { data: prior, error: priorError } = await admin.from("aios_tool_invocations").select("id,task_id,status,approval_id,result,error_code,error_message").eq("organization_id", task.organization_id).eq("idempotency_key", requestedIdempotency).maybeSingle();
      if (!priorError && prior && prior.task_id === task.id) {
        if (prior.status === "succeeded") return json({ task_id: task.id, status: task.status, invocation_id: prior.id, result: task.result ?? prior.result, idempotent_replay: true });
        if (prior.status === "requires_approval") return json({ task_id: task.id, status: task.status, invocation_id: prior.id, approval_id: prior.approval_id, idempotent_replay: true }, 202);
        if (prior.status === "executing") return json({ task_id: task.id, status: task.status, invocation_id: prior.id, idempotent_replay: true }, 202);
        return json({ error: `Task is not executable (current status: ${task.status})`, task_status: task.status, invocation_id: prior.id, invocation_status: prior.status, error_code: prior.error_code ?? null, idempotent_replay: true }, 409);
      }
    }
    return json({ error: `Task is not executable (current status: ${task.status})` }, 409);
  }

  const { data: agent, error: agentError } = await admin.from("aios_agents").select("id,name,role,primary_model,status,authority").eq("id", task.assigned_agent_id).maybeSingle();
  if (agentError || !agent) return json({ error: "Assigned agent not found" }, 500);
  if (agent.status === "suspended") return json({ error: "Agent is suspended" }, 403);

  // Parent mission must be executable before anything is claimed. This is a read-only early exit for a clean 409; it is NOT the
  // authority. The database re-checks task and mission state at the claim (aios_task_mission_gate) and at kernel authorization
  // (aios_assert_invocation_executable), and this handler re-validates again at each boundary below. Accepted mission states are
  // exactly the database gate's: 'queued', or 'running' (including a resumed approved task, because aios_resolve_approval moves
  // the mission blocked_pending_approval -> running when it approves).
  if (!task.mission_id) return json({ error: "Task has no parent mission" }, 422);
  const { data: parentMission, error: parentMissionError } = await admin.from("aios_missions").select("id,status").eq("id", task.mission_id).maybeSingle();
  if (parentMissionError) return json({ error: "Mission lookup failed", detail: parentMissionError.message }, 500);
  if (!parentMission) return json({ error: "Parent mission not found" }, 404);
  if (!["queued", "running"].includes(parentMission.status)) {
    return json({ error: `Parent mission is not executable (current status: ${parentMission.status})`, mission_status: parentMission.status, tool_executed: false }, 409);
  }

  // External-service configuration is checked only after authentication, authorization and resource/state validation, and
  // before the first state mutation. (The read-only idempotent replay above never needs the model.)
  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) return json({ error: "ANTHROPIC_API_KEY is not configured; refusing to fake agent execution" }, 503);

  // Task: atomic compare-and-set (queued/approved -> running). A caller that does not win it stops here, before any model call
  // and before the mission is touched, so a failed or lost claim can never leave the mission 'running'.
  const { data: taskClaimed, error: taskStartError } = await admin.from("aios_tasks").update({ status: "running", started_at: new Date().toISOString() }).eq("id", task.id).eq("status", task.status).select("id");
  // 42501 from the claim is the database refusing to put a task into a live state under a terminal mission (the mission went
  // terminal after the read above). That is a lost race, not a server fault.
  if (taskStartError?.code === "42501") return json({ error: "Parent mission became terminal before the task could start", detail: taskStartError.message, task_id: task.id, tool_executed: false }, 409);
  if (taskStartError) return json({ error: "Failed to start task", detail: taskStartError.message }, 500);
  if (!taskClaimed || taskClaimed.length !== 1) return json({ error: "Task was already claimed by another execution", task_id: task.id }, 409);

  // From here the task is ours and 'running'. Every exit that is not success or an intentional block must leave a terminal,
  // diagnosable state (stage + error) on BOTH the task and its mission. Anything that still slips through is converged by
  // private.aios_reap_stale_tasks() (pg_cron).
  // failTaskAndMission writes an exact result body (callers keep their documented error codes); stage is optional diagnostics.
  const failTaskAndMission = async (result: Record<string, unknown>, stage?: string) => {
    const patch: Record<string, unknown> = { status: "failed", result, completed_at: new Date().toISOString() };
    if (stage) {
      patch.failed_stage = stage;
      patch.last_error = String(result.detail ?? result.error ?? stage).slice(0, 1000);
    }
    const { error: taskErr } = await admin.from("aios_tasks").update(patch).eq("id", task.id).eq("status", "running");
    if (taskErr) console.error(`[execute-task] failed to record task failure (${stage ?? "unstaged"}) for ${task.id}: ${taskErr.message}`);
    const { error: missionErr } = await admin.from("aios_missions").update({ status: "failed", completed_at: new Date().toISOString() }).eq("id", task.mission_id).eq("status", "running");
    if (missionErr) console.error(`[execute-task] failed to record mission failure for ${task.mission_id}: ${missionErr.message}`);
  };
  const failClaimed = async (stage: string, err: unknown, extra: Record<string, unknown> = {}) => {
    const message = String(err).slice(0, 1000);
    await failTaskAndMission({ error: `${stage}_failed`, detail: message, ...extra }, stage);
  };

  // Mission: only the caller that moves queued -> running writes started_at; if it is already running, leave it untouched.
  // The task is already claimed, so a failure here fails the claimed task with a diagnosable stage instead of stranding it.
  const { data: missionStarted, error: missionStartError } = await admin.from("aios_missions").update({ status: "running", started_at: new Date().toISOString() }).eq("id", task.mission_id).eq("status", "queued").select("id");
  if (missionStartError) {
    await failClaimed("mission_start", missionStartError.message, { tool_executed: false });
    return json({ error: "Failed to start mission", detail: missionStartError.message, tool_executed: false }, 500);
  }

  // Re-validate execution authority at a boundary. Authority is: our task is still 'running' AND its mission is 'running'. A
  // cancelled/failed/completed/expired mission cascades its live tasks to terminal in the database, so a mismatch means the
  // database has already withdrawn authority. We stop WITHOUT writing to the task or mission (the database terminal state is
  // the truth, and the handler must not overwrite it). Returns a Response to send when authority is gone, or null to proceed.
  const revalidateAuthority = async (stage: string, onLost?: () => Promise<void>, toolExecuted = false): Promise<Response | null> => {
    const [taskRead, missionRead] = await Promise.all([
      admin.from("aios_tasks").select("status").eq("id", task.id).maybeSingle(),
      admin.from("aios_missions").select("status").eq("id", task.mission_id).maybeSingle(),
    ]);
    const readError = taskRead.error ?? missionRead.error;
    if (readError) {
      await failClaimed(`${stage}_revalidation`, readError.message, { tool_executed: toolExecuted, tool_reexecuted: false, tool_result_preserved: toolExecuted });
      return json({ error: "Execution authority could not be re-validated", detail: readError.message, stage, tool_executed: toolExecuted, tool_reexecuted: false, tool_result_preserved: toolExecuted }, 500);
    }
    const taskStatus = taskRead.data?.status ?? "missing";
    const missionStatus = missionRead.data?.status ?? "missing";
    if (taskStatus === "running" && missionStatus === "running") return null;
    console.error(`[execute-task] execution authority lost at ${stage} for task ${task.id}: task=${taskStatus} mission=${missionStatus}`);
    if (onLost) await onLost();
    return json({ error: "Execution authority was withdrawn; processing stopped", stage, task_status: taskStatus, mission_status: missionStatus, task_id: task.id, tool_executed: toolExecuted, tool_reexecuted: false, tool_result_preserved: toolExecuted }, 409);
  };

  // The conditional queued -> running update only counts if it touched a row. Zero rows is fine ONLY when the mission is
  // already 'running' (another task of the mission started it). Any other state means the mission is no longer executable.
  if (!missionStarted || missionStarted.length === 0) {
    const lost = await revalidateAuthority("mission_start");
    if (lost) return lost;
  }

  const model = "claude-sonnet-4-6";
  const allowedTools = agent.authority?.allowed_tools ?? [];
  const proposalPrompt = `You are the execution planner for AiOS agent ${agent.name}. The database kernel controls authorization. Propose exactly one tool call for this task. Return ONLY JSON: {"tool_key":string,"arguments":object}. Choose only from these contract tools: ${JSON.stringify(allowedTools)}. Never invent a tool. Task: ${task.title}. Instructions: ${task.instructions}`;
  let proposal: Awaited<ReturnType<typeof callClaude>>;
  try {
    proposal = await callClaude(anthropicKey, model, proposalPrompt, 600);
  } catch (e) {
    await failClaimed("model_proposal", e, { tool_executed: false });
    return json({ error: "Model request failed before any tool was proposed", detail: String(e), tool_executed: false }, 502);
  }
  await bestEffort("model_runs:tool_proposal", admin.from("aios_model_runs").insert({ organization_id: task.organization_id, agent_id: agent.id, task_id: task.id, provider: "anthropic", model, input_hash: await sha256(proposalPrompt), output_hash: await sha256(proposal.text), prompt_reference: "kernel.tool_selection.v2.registry", input_tokens: proposal.input_tokens, output_tokens: proposal.output_tokens, latency_ms: proposal.latency_ms, status: "succeeded", outcome: "tool_proposal" }));

  // The model call is the longest window in this handler. Authority may have been withdrawn while it ran (mission cancelled,
  // task reaped or cancelled, approval lapsed). Do not continue processing the proposal if it was.
  {
    const lost = await revalidateAuthority("after_model_proposal");
    if (lost) return lost;
  }

  let proposed: { tool_key: string; arguments: Record<string, unknown> };
  try {
    proposed = parseJsonObject(proposal.text);
    if (typeof proposed.tool_key !== "string" || !proposed.arguments || typeof proposed.arguments !== "object" || Array.isArray(proposed.arguments)) throw new Error("invalid tool proposal shape");
  } catch (e) {
    await failTaskAndMission({ error: "invalid_model_tool_proposal", detail: String(e) }, "proposal_validation");
    return json({ error: "Model produced an invalid tool proposal", detail: String(e) }, 422);
  }

  const { data: tool, error: toolError } = await admin.from("aios_tools").select("id,tool_key,name,version,risk_level,input_schema,output_schema,handler,status,is_enabled,requires_approval,idempotency_required,timeout_ms").eq("tool_key", proposed.tool_key).maybeSingle();
  if (toolError) {
    await failClaimed("tool_registry_lookup", toolError.message, { tool_executed: false });
    return json({ error: "Tool registry lookup failed", detail: toolError.message }, 500);
  }
  if (!tool || !tool.is_enabled || tool.status !== "active") {
    await failTaskAndMission({ error: "tool_unavailable", tool_key: proposed.tool_key }, "tool_unavailable");
    return json({ error: "Tool is unavailable in the registry" }, 422);
  }

  try { validateAgainstSchema(proposed.arguments, tool.input_schema); }
  catch (e) {
    await failTaskAndMission({ error: "invalid_tool_arguments", detail: String(e), tool_key: tool.tool_key, registry_version: tool.version }, "argument_validation");
    return json({ error: "Tool arguments rejected by registry schema", detail: String(e), tool_key: tool.tool_key, registry_version: tool.version }, 422);
  }

  const argsHash = await sha256(proposed.arguments);
  const idempotencyKey = requestedIdempotency ?? `${task.id}:${tool.tool_key}:v${tool.version}:${argsHash}`;
  if (tool.idempotency_required && !idempotencyKey) return json({ error: "Tool requires an idempotency key" }, 400);

  const sameBinding = (row: Record<string, any>) =>
    row.agent_id === agent.id && row.tool_key === tool.tool_key && (row.task_id ?? null) === task.id &&
    canonicalJson(row.arguments ?? {}) === canonicalJson(proposed.arguments);
  // Existing invocation for this key is authoritative: validate it is the same request, then replay its state. Never proceeds to another insert.
  const replayExisting = async (row: Record<string, any>): Promise<Response> => {
    if (!sameBinding(row)) {
      await failTaskAndMission({ error: "idempotency_key_conflict", tool_key: tool.tool_key }, "idempotency_conflict");
      return json({ error: "Idempotency key is already bound to a different request" }, 409);
    }
    switch (row.status) {
      case "succeeded": return json({ task_id: task.id, status: "completed", invocation_id: row.id, result: row.result, idempotent_replay: true });
      case "requires_approval": return json({ task_id: task.id, status: "blocked_pending_approval", invocation_id: row.id, approval_id: row.approval_id, idempotent_replay: true }, 202);
      case "executing": return json({ task_id: task.id, status: "running", invocation_id: row.id, idempotent_replay: true }, 202);
      case "denied":
        await failTaskAndMission({ denied: true, reason: row.result?.kernel_reason, idempotent_replay: true });
        return json({ task_id: task.id, status: "failed", invocation_id: row.id, reason: row.result?.kernel_reason, idempotent_replay: true }, 403);
      case "failed":
        await failTaskAndMission({ error: row.error_code ?? "invocation_failed", detail: row.error_message, idempotent_replay: true });
        return json({ task_id: task.id, status: "failed", invocation_id: row.id, error: row.error_code ?? "invocation_failed", detail: row.error_message, idempotent_replay: true }, row.error_code === "AUTHORIZATION_RECHECK_FAILED" ? 403 : 502);
      default:
        return json({ error: `Idempotency key is bound to an invocation in state ${row.status}`, invocation_id: row.id }, 409);
    }
  };

  const { data: existing, error: existingError } = await admin.from("aios_tool_invocations").select("*").eq("organization_id", task.organization_id).eq("idempotency_key", idempotencyKey).maybeSingle();
  if (existingError) {
    await failClaimed("invocation_lookup", existingError.message, { tool_executed: false });
    return json({ error: "Invocation lookup failed", detail: existingError.message }, 500);
  }
  // Resume: a human approved this exact invocation (same agent, tool, task, arguments). The approval is bound to this row,
  // so run it as-is: skip the insert and fall through to kernel authorization and execution.
  let invocation: Record<string, any>;
  if (existing && existing.status === "approved" && sameBinding(existing)) {
    invocation = existing;
  } else {
  if (existing) return await replayExisting(existing);

  const { data: inserted, error: invError } = await admin.from("aios_tool_invocations").insert({ organization_id: task.organization_id, agent_id: agent.id, task_id: task.id, tool_name: tool.tool_key, tool_key: tool.tool_key, arguments: proposed.arguments, risk_level: tool.risk_level, requested_by: userData.user.id, idempotency_key: idempotencyKey, request_id: crypto.randomUUID() }).select("*").single();
  if (invError) {
    if (invError.code === "23505") {
      const { data: winner, error: winnerError } = await admin.from("aios_tool_invocations").select("*").eq("organization_id", task.organization_id).eq("idempotency_key", idempotencyKey).maybeSingle();
      if (winnerError) {
        await failClaimed("idempotency_winner_lookup", winnerError.message, { tool_executed: false });
        return json({ error: "Duplicate invocation detected but winner lookup failed", detail: winnerError.message }, 500);
      }
      if (!winner) {
        await failClaimed("idempotency_winner_lookup", "original invocation not found after duplicate-key conflict", { tool_executed: false });
        return json({ error: "Duplicate invocation detected but original invocation was not found" }, 409);
      }
      return await replayExisting(winner);
    }
    await failTaskAndMission({ error: "invocation_creation_failed", detail: invError.message }, "invocation_creation");
    return json({ error: "Failed to create invocation", detail: invError.message }, 500);
  }
  invocation = inserted;
  }

  if (invocation.status === "denied") {
    await failTaskAndMission({ denied: true, reason: invocation.result?.kernel_reason });
    return json({ task_id: task.id, status: "failed", invocation_id: invocation.id, reason: invocation.result?.kernel_reason }, 403);
  }

  if (invocation.status === "requires_approval") {
    await admin.from("aios_tasks").update({ status: "blocked_pending_approval" }).eq("id", task.id).eq("status", "running");
    await admin.from("aios_missions").update({ status: "blocked_pending_approval" }).eq("id", task.mission_id).eq("status", "running");
    return json({ task_id: task.id, status: "blocked_pending_approval", invocation_id: invocation.id, approval_id: invocation.approval_id, reason: invocation.result?.kernel_reason }, 202);
  }

  // Last handler-side check before the kernel claims the invocation for execution. If authority is gone, withdraw the invocation
  // we created or resumed (approved -> cancelled, the same transition the mission cascade uses) so no approved row is orphaned.
  {
    const lost = await revalidateAuthority("before_authorization", async () => {
      const { error: cancelError } = await admin.from("aios_tool_invocations").update({ status: "cancelled", completed_at: new Date().toISOString(), error_code: "EXECUTION_AUTHORITY_LOST", error_message: "task or mission left 'running' before kernel authorization" }).eq("id", invocation.id).eq("status", "approved");
      if (cancelError) console.error(`[execute-task] failed to cancel invocation ${invocation.id} after authority loss: ${cancelError.message}`);
    });
    if (lost) return lost;
  }

  const { data: authorized, error: authError } = await admin.rpc("aios_kernel_authorize_invocation", { p_invocation_id: invocation.id });
  if (authError || !authorized) {
    await admin.from("aios_tool_invocations").update({ status: "failed", error_code: "AUTHORIZATION_RECHECK_FAILED", error_message: authError?.message ?? "kernel authorization failed", completed_at: new Date().toISOString() }).eq("id", invocation.id).eq("status", "approved");
    await failTaskAndMission({ error: "kernel_authorization_failed", detail: authError?.message }, "kernel_authorization");
    return json({ error: "Kernel authorization failed", detail: authError?.message }, 403);
  }

  let toolResult: Record<string, unknown>;
  const toolStarted = Date.now();
  try {
    toolResult = await executeRegisteredHandler(tool.handler, proposed.arguments, task.organization_id, admin);
    validateAgainstSchema(toolResult, tool.output_schema, "toolResult");
  } catch (e) {
    const message = String(e);
    await admin.from("aios_tool_invocations").update({ status: "failed", error_code: "TOOL_EXECUTION_FAILED", error_message: message, retry_count: 0, completed_at: new Date().toISOString() }).eq("id", invocation.id).eq("status", "executing");
    await failTaskAndMission({ error: "tool_execution_failed", detail: message }, "tool_execution");
    return json({ error: "Registered tool execution failed", detail: message }, 502);
  }
  const toolLatency = Date.now() - toolStarted;
  const resultHash = await sha256(toolResult);

  const { error: invSuccessError } = await admin.from("aios_tool_invocations").update({ status: "succeeded", result: toolResult, result_hash: resultHash, completed_at: new Date().toISOString() }).eq("id", invocation.id).eq("status", "executing");
  if (invSuccessError) {
    await failClaimed("seal_invocation", invSuccessError.message, { invocation_id: invocation.id, tool_executed: true, tool_reexecuted: false });
    return json({ error: "Failed to seal invocation result", detail: invSuccessError.message, invocation_id: invocation.id }, 500);
  }

  // The tool result is now durably sealed. If cancellation/reaping won during the tool call, stop before spending another model call.
  // The invocation remains succeeded and is the durable record of the side effect.
  {
    const lost = await revalidateAuthority("after_tool_execution", undefined, true);
    if (lost) return lost;
  }

  const finalPrompt = `You are ${agent.name}, an AiOS ${agent.role}. Analyze ONLY the verified tool result below. Task: ${task.title}. Return ONLY JSON with keys summary (string) and findings (array of exactly five objects with category, count, problem). Do not invent categories or counts. Tool result: ${JSON.stringify(toolResult)}`;
  let final: Awaited<ReturnType<typeof callClaude>>;
  try {
    final = await callClaude(anthropicKey, model, finalPrompt, 1200);
  } catch (e) {
    // The tool already succeeded and its result is sealed on the invocation. If authority was withdrawn while final analysis ran,
    // preserve the canceller's terminal state and report the lost authority instead of recording an ordinary failure.
    const lost = await revalidateAuthority("final_analysis_error", undefined, true);
    if (lost) return lost;
    await failClaimed("final_analysis", e, { invocation_id: invocation.id, tool_executed: true, tool_reexecuted: false, tool_result_preserved: true });
    return json({ error: "Final analysis failed after the tool succeeded; the tool result is preserved and the tool was not re-executed", detail: String(e), invocation_id: invocation.id }, 502);
  }
  await bestEffort("model_runs:task_analysis", admin.from("aios_model_runs").insert({ organization_id: task.organization_id, agent_id: agent.id, task_id: task.id, provider: "anthropic", model, input_hash: await sha256(finalPrompt), output_hash: await sha256(final.text), prompt_reference: "kernel.task_analysis.v2.registry", input_tokens: final.input_tokens, output_tokens: final.output_tokens, latency_ms: final.latency_ms, status: "succeeded", outcome: "task_analysis" }));

  // Re-check after final analysis too. The task completion CAS below remains the final fence for a cancellation that wins
  // after this read but before the UPDATE obtains its row lock.
  {
    const lost = await revalidateAuthority("after_final_analysis", undefined, true);
    if (lost) return lost;
  }

  let finalOutput: any;
  try { finalOutput = parseJsonObject(final.text); } catch { finalOutput = { summary: final.text, findings: [] }; }
  const expected = ((toolResult.summary as Array<{category:string,count:number}>) ?? []).slice(0,5);
  const findings = Array.isArray(finalOutput.findings) ? finalOutput.findings : [];
  const categoriesOk = expected.every((x) => findings.some((f: any) => f?.category === x.category && Number(f?.count) === x.count));
  const completeness = findings.length === 5 ? 1 : Math.min(1, findings.length / 5);
  const correctness = categoriesOk ? 1 : Math.max(0, expected.filter((x) => findings.some((f: any) => f?.category === x.category && Number(f?.count) === x.count)).length / Math.max(1, expected.length));
  const policy = 1;
  const efficiency = toolLatency < 3000 ? 1 : 0.8;
  const executionSuccess = 1;
  const score = (correctness + completeness + policy + efficiency + executionSuccess) / 5;

  const taskResult = { objective: task.instructions, tool: tool.tool_key, registry_version: tool.version, handler: tool.handler, tool_result: { count: toolResult.count, summary: toolResult.summary }, output: finalOutput, evaluation: { overall_score: score, correctness, completeness, policy_compliance: policy, tool_efficiency: efficiency, execution_success: executionSuccess }, model_run: { provider: "anthropic", model } };
  const { data: taskCompletedRows, error: taskCompleteError } = await admin.from("aios_tasks").update({ status: "completed", result: taskResult, completed_at: new Date().toISOString() }).eq("id", task.id).eq("status", "running").select("id");
  if (taskCompleteError) {
    await failClaimed("task_completion", taskCompleteError.message, { invocation_id: invocation.id, tool_executed: true, tool_reexecuted: false });
    return json({ error: "Failed to complete task", detail: taskCompleteError.message, invocation_id: invocation.id }, 500);
  }
  // Zero rows means the task left 'running' while the tool executed (mission cancelled/failed/expired, or the reaper took it).
  // The tool side effect already happened and its result is sealed on the invocation; it must never be reported as a completed
  // task. Report the real state, do not touch the mission or record an evaluation, and never re-run the tool.
  if (!taskCompletedRows || taskCompletedRows.length !== 1) {
    const { data: currentTask } = await admin.from("aios_tasks").select("status").eq("id", task.id).maybeSingle();
    console.error(`[execute-task] task ${task.id} was no longer running at completion (status=${currentTask?.status ?? "missing"}); tool already executed, result preserved on invocation ${invocation.id}`);
    return json({ error: "Task is no longer running; completion was not recorded", task_id: task.id, task_status: currentTask?.status ?? "missing", invocation_id: invocation.id, tool_executed: true, tool_reexecuted: false, tool_result_preserved: true }, 409);
  }

  // The task is now durably completed. Settle the mission and episodic memory BEFORE the evaluation record, so a failed
  // evaluation write can never leave the mission stuck 'running' or drop memory of a completed task.
  const { data: remaining } = await admin.from("aios_tasks").select("status").eq("mission_id", task.mission_id);
  const missionDone = (remaining ?? []).length > 0 && (remaining ?? []).every((x) => x.status === "completed");
  // Report the mission's real status, not an assumption: the conditional update only counts if it touched a row.
  let missionStatus = "running";
  if (missionDone) {
    const { data: missionDoneRows, error: missionDoneError } = await admin.from("aios_missions").update({ status: "completed", completed_at: new Date().toISOString() }).eq("id", task.mission_id).eq("status", "running").select("id");
    if (missionDoneError) console.error(`[execute-task] failed to complete mission ${task.mission_id}: ${missionDoneError.message}`);
    if (!missionDoneError && missionDoneRows && missionDoneRows.length === 1) {
      missionStatus = "completed";
    } else {
      const { data: currentMission } = await admin.from("aios_missions").select("status").eq("id", task.mission_id).maybeSingle();
      missionStatus = currentMission?.status ?? "unknown";
    }
  }

  await bestEffort("memory:episodic", admin.from("aios_memory").insert({ organization_id: task.organization_id, agent_id: agent.id, scope: "episodic", content: JSON.stringify({ task_objective: task.instructions, tool_used: tool.tool_key, registry_version: tool.version, important_findings: expected, result_summary: finalOutput.summary ?? null, success: true, evaluation_score: score, timestamp: new Date().toISOString() }), metadata: { task_id: task.id, mission_id: task.mission_id, invocation_id: invocation.id, memory_type: "task_execution" } }));

  const { data: evaluation, error: evaluationError } = await admin.rpc("aios_record_evaluation", { p_task_id: task.id, p_invocation_id: invocation.id, p_correctness: correctness, p_completeness: completeness, p_policy: policy, p_efficiency: efficiency, p_execution: executionSuccess, p_summary: `Kernel evaluation: ${Math.round(score * 100)}%` });
  if (evaluationError) {
    console.error(`[execute-task] evaluation record failed for task ${task.id}: ${evaluationError.message}`);
    return json({ error: "Evaluation failed", detail: evaluationError.message, task_id: task.id, task_completed: true, mission_status: missionStatus }, 500);
  }

  return json({ task_id: task.id, invocation_id: invocation.id, status: "completed", tool_key: tool.tool_key, registry_version: tool.version, handler: tool.handler, tool_latency_ms: toolLatency, result: taskResult, evaluation, mission_status: missionStatus }, 200);
});
