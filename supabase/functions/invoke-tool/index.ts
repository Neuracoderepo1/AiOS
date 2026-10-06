import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalJson).join(",") + "]";
  }

  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    return "{" +
      Object.keys(object)
        .sort()
        .map((key) => JSON.stringify(key) + ":" + canonicalJson(object[key]))
        .join(",") +
      "}";
  }

  return JSON.stringify(value === undefined ? null : value);
}

type InvocationRequest = {
  agent_id: string;
  tool_name: string;
  task_id: string | null;
  risk_level: string;
  arguments: unknown;
};

function sameRequest(
  row: Record<string, unknown>,
  request: InvocationRequest,
): boolean {
  return (
    row.agent_id === request.agent_id &&
    row.tool_key === request.tool_name &&
    (row.task_id ?? null) === request.task_id &&
    row.risk_level === request.risk_level &&
    canonicalJson(row.arguments ?? {}) === canonicalJson(request.arguments)
  );
}

const EXISTING_COLUMNS =
  "id,status,approval_id,agent_id,task_id,tool_key,risk_level,arguments";

async function findExisting(
  admin: ReturnType<typeof createClient>,
  organizationId: string,
  idempotencyKey: string,
) {
  return await admin
    .from("aios_tool_invocations")
    .select(EXISTING_COLUMNS)
    .eq("organization_id", organizationId)
    .eq("idempotency_key", idempotencyKey)
    .maybeSingle();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const auth = req.headers.get("Authorization");
  if (!auth) {
    return json({ error: "Missing Authorization header" }, 401);
  }

  if (Number(req.headers.get("content-length") ?? 0) > 65536) {
    return json({ error: "Request too large" }, 413);
  }

  let body: Record<string, unknown>;

  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const agent_id = body.agent_id as string | undefined;
  const tool_name = body.tool_name as string | undefined;
  const task_id = (body.task_id as string | undefined) ?? null;
  const risk_level = body.risk_level as string | undefined;
  const idempotency_key = body.idempotency_key as string | undefined;
  const args = (body.arguments as Record<string, unknown>) ?? {};

  if (!agent_id || !tool_name || !risk_level || !idempotency_key) {
    return json({
      error: "agent_id, tool_name, risk_level, and idempotency_key are required",
    }, 400);
  }

  if (!["low", "medium", "high"].includes(risk_level)) {
    return json({ error: "invalid risk level" }, 422);
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const secret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const user = createClient(url, anon, {
    global: { headers: { Authorization: auth } },
  });

  const { data: u, error: ue } = await user.auth.getUser();

  if (ue || !u?.user) {
    return json({ error: "Invalid or expired session" }, 401);
  }

  const admin = createClient(url, secret);

  const {
    data: agent,
    error: ae,
  } = await admin
    .from("aios_agents")
    .select("id,organization_id,status")
    .eq("id", agent_id)
    .maybeSingle();

  if (ae) {
    return json({ error: "Agent lookup failed" }, 500);
  }

  if (!agent) {
    return json({ error: "Agent not found" }, 404);
  }

  if (agent.status === "suspended") {
    return json({ error: "Agent is suspended" }, 403);
  }

  const {
    data: member,
    error: me,
  } = await user.rpc("aios_is_org_member", {
    org_id: agent.organization_id,
  });

  if (me) {
    return json({ error: "Authorization check failed" }, 500);
  }

  if (!member) {
    return json({ error: "Not authorized for this organization" }, 403);
  }

  const request: InvocationRequest = {
    agent_id,
    tool_name,
    task_id,
    risk_level,
    arguments: args,
  };

  const {
    data: existing,
    error: existingError,
  } = await findExisting(
    admin,
    agent.organization_id,
    idempotency_key,
  );

  if (existingError) {
    return json({ error: "Invocation lookup failed" }, 500);
  }

  if (existing) {
    if (!sameRequest(existing, request)) {
      return json({
        error: "Idempotency key is already bound to a different invocation",
      }, 409);
    }

    return json({
      invocation_id: existing.id,
      status: existing.status,
      approval_id: existing.approval_id,
      idempotent_replay: true,
    }, 200);
  }

  const {
    data: inv,
    error: ie,
  } = await admin
    .from("aios_tool_invocations")
    .insert({
      organization_id: agent.organization_id,
      agent_id: agent.id,
      task_id,
      tool_name,
      tool_key: tool_name,
      arguments: args,
      risk_level,
      requested_by: u.user.id,
      idempotency_key,
      request_id: crypto.randomUUID(),
    })
    .select("id,status,approval_id,tool_key,authorization_version")
    .single();

  if (ie) {
    if (ie.code === "23505") {
      const {
        data: winner,
        error: winnerError,
      } = await findExisting(
        admin,
        agent.organization_id,
        idempotency_key,
      );

      if (winnerError) {
        return json({
          error: "Duplicate invocation detected but winner lookup failed",
        }, 500);
      }

      if (!winner) {
        return json({
          error: "Duplicate invocation detected but original invocation was not found",
        }, 409);
      }

      if (!sameRequest(winner, request)) {
        return json({
          error: "Idempotency key is already bound to a different invocation",
        }, 409);
      }

      return json({
        invocation_id: winner.id,
        status: winner.status,
        approval_id: winner.approval_id,
        idempotent_replay: true,
      }, 200);
    }

    if (ie.code === "42501") {
      return json({ error: "Invocation not authorized" }, 403);
    }

    if (ie.code === "22023") {
      return json({
        error: "Invocation failed registry validation",
      }, 422);
    }

    if (ie.code === "23514") {
      return json({
        error: "Invocation failed integrity validation",
      }, 422);
    }

    return json({ error: "Failed to create invocation" }, 500);
  }

  return json({
    invocation_id: inv.id,
    status: inv.status,
    gated: inv.status === "requires_approval",
    agent_id: agent.id,
    tool_key: inv.tool_key,
    approval_id: inv.approval_id,
  }, 201);
});
