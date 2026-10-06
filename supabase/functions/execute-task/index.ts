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

async function sha256(value: unknown): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
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

async function executeRegisteredHandler(handler: string, args: Record<string, unknown>, organizationId: string, admin: ReturnType<typeof createClient>): Promise<Record<string, unknown>> {
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
      const rows = tickets ?? [];
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

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }
  const task_id = body.task_id as string | undefined;
  const requestedIdempotency = body.idempotency_key as string | undefined;
  if (!task_id) return json({ error: "task_id is required" }, 400);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) return json({ error: "ANTHROPIC_API_KEY is not configured; refusing to fake agent execution" }, 503);

  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: "Invalid or expired session" }, 401);
  const admin = createClient(supabaseUrl, serviceKey);

  const { data: task, error: taskError } = await admin.from("aios_tasks").select("id,organization_id,mission_id,assigned_agent_id,title,instructions,status,risk_level,result").eq("id", task_id).maybeSingle();
  if (taskError) return json({ error: "Task lookup failed", detail: taskError.message }, 500);
  if (!task) return json({ error: "Task not found" }, 404);
  const { data: member } = await userClient.rpc("aios_is_org_member", { org_id: task.organization_id });
  if (!member) return json({ error: "You are not a member of this organization" }, 403);
  if (!task.assigned_agent_id) return json({ error: "Task has no assigned agent" }, 422);
  if (!["queued", "approved"].includes(task.status)) return json({ error: `Task is not executable (current status: ${task.status})` }, 409);

  const { data: agent, error: agentError } = await admin.from("aios_agents").select("id,name,role,primary_model,status,authority").eq("id", task.assigned_agent_id).maybeSingle();
  if (agentError || !agent) return json({ error: "Assigned agent not found" }, 500);
  if (agent.status === "suspended") return json({ error: "Agent is suspended" }, 403);

  const { error: missionStartError } = await admin.from("aios_missions").update({ status: "running", started_at: new Date().toISOString() }).eq("id", task.mission_id).in("status", ["queued", "running"]);
  if (missionStartError) return json({ error: "Failed to start mission", detail: missionStartError.message }, 500);

  const { error: taskStartError } = await admin.from("aios_tasks").update({ status: "running", started_at: new Date().toISOString() }).eq("id", task.id).eq("status", task.status);
  if (taskStartError) return json({ error: "Failed to start task", detail: taskStartError.message }, 500);

  const model = "claude-sonnet-4-6";
  const allowedTools = agent.authority?.allowed_tools ?? [];
  const proposalPrompt = `You are the execution planner for AiOS agent ${agent.name}. The database kernel controls authorization. Propose exactly one tool call for this task. Return ONLY JSON: {"tool_key":string,"arguments":object}. Choose only from these contract tools: ${JSON.stringify(allowedTools)}. Never invent a tool. Task: ${task.title}. Instructions: ${task.instructions}`;
  const proposal = await callClaude(anthropicKey, model, proposalPrompt, 600);
  await admin.from("aios_model_runs").insert({ organization_id: task.organization_id, agent_id: agent.id, task_id: task.id, provider: "anthropic", model, input_hash: await sha256(proposalPrompt), output_hash: await sha256(proposal.text), prompt_reference: "kernel.tool_selection.v2.registry", input_tokens: proposal.input_tokens, output_tokens: proposal.output_tokens, latency_ms: proposal.latency_ms, status: "succeeded", outcome: "tool_proposal" });

  let proposed: { tool_key: string; arguments: Record<string, unknown> };
  try {
    proposed = parseJsonObject(proposal.text);
    if (typeof proposed.tool_key !== "string" || !proposed.arguments || typeof proposed.arguments !== "object" || Array.isArray(proposed.arguments)) throw new Error("invalid tool proposal shape");
  } catch (e) {
    await admin.from("aios_tasks").update({ status: "failed", result: { error: "invalid_model_tool_proposal", detail: String(e) }, completed_at: new Date().toISOString() }).eq("id", task.id).eq("status", "running");
    return json({ error: "Model produced an invalid tool proposal", detail: String(e) }, 422);
  }

  const { data: tool, error: toolError } = await admin.from("aios_tools").select("id,tool_key,name,version,risk_level,input_schema,output_schema,handler,status,is_enabled,requires_approval,idempotency_required,timeout_ms").eq("tool_key", proposed.tool_key).maybeSingle();
  if (toolError) return json({ error: "Tool registry lookup failed", detail: toolError.message }, 500);
  if (!tool || !tool.is_enabled || tool.status !== "active") {
    await admin.from("aios_tasks").update({ status: "failed", result: { error: "tool_unavailable", tool_key: proposed.tool_key }, completed_at: new Date().toISOString() }).eq("id", task.id).eq("status", "running");
    return json({ error: "Tool is unavailable in the registry" }, 422);
  }

  try { validateAgainstSchema(proposed.arguments, tool.input_schema); }
  catch (e) {
    await admin.from("aios_tasks").update({ status: "failed", result: { error: "invalid_tool_arguments", detail: String(e), tool_key: tool.tool_key, registry_version: tool.version }, completed_at: new Date().toISOString() }).eq("id", task.id).eq("status", "running");
    return json({ error: "Tool arguments rejected by registry schema", detail: String(e), tool_key: tool.tool_key, registry_version: tool.version }, 422);
  }

  const argsHash = await sha256(proposed.arguments);
  const idempotencyKey = requestedIdempotency ?? `${task.id}:${tool.tool_key}:v${tool.version}:${argsHash}`;
  if (tool.idempotency_required && !idempotencyKey) return json({ error: "Tool requires an idempotency key" }, 400);

  const { data: existing } = await admin.from("aios_tool_invocations").select("*").eq("organization_id", task.organization_id).eq("idempotency_key", idempotencyKey).maybeSingle();
  if (existing) {
    if (existing.status === "succeeded") return json({ task_id: task.id, status: "completed", invocation_id: existing.id, result: existing.result, idempotent_replay: true });
    if (existing.status === "requires_approval") return json({ task_id: task.id, status: "blocked_pending_approval", invocation_id: existing.id, approval_id: existing.approval_id, idempotent_replay: true }, 202);
    if (existing.status === "executing") return json({ task_id: task.id, status: "running", invocation_id: existing.id, idempotent_replay: true }, 202);
  }

  const { data: invocation, error: invError } = await admin.from("aios_tool_invocations").insert({ organization_id: task.organization_id, agent_id: agent.id, task_id: task.id, tool_name: tool.tool_key, tool_key: tool.tool_key, arguments: proposed.arguments, risk_level: tool.risk_level, requested_by: userData.user.id, idempotency_key: idempotencyKey, request_id: crypto.randomUUID() }).select("*").single();
  if (invError) {
    if (invError.code === "23505") return json({ error: "Duplicate invocation prevented by idempotency key" }, 409);
    await admin.from("aios_tasks").update({ status: "failed", result: { error: "invocation_creation_failed", detail: invError.message }, completed_at: new Date().toISOString() }).eq("id", task.id).eq("status", "running");
    return json({ error: "Failed to create invocation", detail: invError.message }, 500);
  }

  if (invocation.status === "denied") {
    await admin.from("aios_tasks").update({ status: "failed", result: { denied: true, reason: invocation.result?.kernel_reason }, completed_at: new Date().toISOString() }).eq("id", task.id).eq("status", "running");
    await admin.from("aios_missions").update({ status: "failed", completed_at: new Date().toISOString() }).eq("id", task.mission_id).eq("status", "running");
    return json({ task_id: task.id, status: "failed", invocation_id: invocation.id, reason: invocation.result?.kernel_reason }, 403);
  }

  if (invocation.status === "requires_approval") {
    await admin.from("aios_tasks").update({ status: "blocked_pending_approval" }).eq("id", task.id).eq("status", "running");
    await admin.from("aios_missions").update({ status: "blocked_pending_approval" }).eq("id", task.mission_id).eq("status", "running");
    return json({ task_id: task.id, status: "blocked_pending_approval", invocation_id: invocation.id, approval_id: invocation.approval_id, reason: invocation.result?.kernel_reason }, 202);
  }

  const { data: authorized, error: authError } = await admin.rpc("aios_kernel_authorize_invocation", { p_invocation_id: invocation.id });
  if (authError || !authorized) {
    await admin.from("aios_tool_invocations").update({ status: "failed", error_code: "AUTHORIZATION_RECHECK_FAILED", error_message: authError?.message ?? "kernel authorization failed", completed_at: new Date().toISOString() }).eq("id", invocation.id).eq("status", "approved");
    await admin.from("aios_tasks").update({ status: "failed", result: { error: "kernel_authorization_failed", detail: authError?.message }, completed_at: new Date().toISOString() }).eq("id", task.id).eq("status", "running");
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
    await admin.from("aios_tasks").update({ status: "failed", result: { error: "tool_execution_failed", detail: message }, completed_at: new Date().toISOString() }).eq("id", task.id).eq("status", "running");
    await admin.from("aios_missions").update({ status: "failed", completed_at: new Date().toISOString() }).eq("id", task.mission_id).eq("status", "running");
    return json({ error: "Registered tool execution failed", detail: message }, 502);
  }
  const toolLatency = Date.now() - toolStarted;
  const resultHash = await sha256(toolResult);

  const { error: invSuccessError } = await admin.from("aios_tool_invocations").update({ status: "succeeded", result: toolResult, result_hash: resultHash, completed_at: new Date().toISOString() }).eq("id", invocation.id).eq("status", "executing");
  if (invSuccessError) return json({ error: "Failed to seal invocation result", detail: invSuccessError.message }, 500);

  const finalPrompt = `You are ${agent.name}, an AiOS ${agent.role}. Analyze ONLY the verified tool result below. Task: ${task.title}. Return ONLY JSON with keys summary (string) and findings (array of exactly five objects with category, count, problem). Do not invent categories or counts. Tool result: ${JSON.stringify(toolResult)}`;
  const final = await callClaude(anthropicKey, model, finalPrompt, 1200);
  await admin.from("aios_model_runs").insert({ organization_id: task.organization_id, agent_id: agent.id, task_id: task.id, provider: "anthropic", model, input_hash: await sha256(finalPrompt), output_hash: await sha256(final.text), prompt_reference: "kernel.task_analysis.v2.registry", input_tokens: final.input_tokens, output_tokens: final.output_tokens, latency_ms: final.latency_ms, status: "succeeded", outcome: "task_analysis" });

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
  const { error: taskCompleteError } = await admin.from("aios_tasks").update({ status: "completed", result: taskResult, completed_at: new Date().toISOString() }).eq("id", task.id).eq("status", "running");
  if (taskCompleteError) return json({ error: "Failed to complete task", detail: taskCompleteError.message }, 500);

  const { data: evaluation, error: evaluationError } = await admin.rpc("aios_record_evaluation", { p_task_id: task.id, p_invocation_id: invocation.id, p_correctness: correctness, p_completeness: completeness, p_policy: policy, p_efficiency: efficiency, p_execution: executionSuccess, p_summary: `Kernel evaluation: ${Math.round(score * 100)}%` });
  if (evaluationError) return json({ error: "Evaluation failed", detail: evaluationError.message }, 500);

  await admin.from("aios_memory").insert({ organization_id: task.organization_id, agent_id: agent.id, scope: "episodic", content: JSON.stringify({ task_objective: task.instructions, tool_used: tool.tool_key, registry_version: tool.version, important_findings: expected, result_summary: finalOutput.summary ?? null, success: true, evaluation_score: score, timestamp: new Date().toISOString() }), metadata: { task_id: task.id, mission_id: task.mission_id, invocation_id: invocation.id, memory_type: "task_execution" } });

  const { data: remaining } = await admin.from("aios_tasks").select("status").eq("mission_id", task.mission_id);
  const missionDone = (remaining ?? []).length > 0 && (remaining ?? []).every((x) => x.status === "completed");
  if (missionDone) await admin.from("aios_missions").update({ status: "completed", completed_at: new Date().toISOString() }).eq("id", task.mission_id).eq("status", "running");

  return json({ task_id: task.id, invocation_id: invocation.id, status: "completed", tool_key: tool.tool_key, registry_version: tool.version, handler: tool.handler, tool_latency_ms: toolLatency, result: taskResult, evaluation, mission_status: missionDone ? "completed" : "running" }, 200);
});
