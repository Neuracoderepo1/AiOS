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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "Missing Authorization header" }, 401);
  if (Number(req.headers.get("content-length") ?? 0) > 16384) return json({ error: "Request too large" }, 413);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const missionId = body.mission_id;
  if (typeof missionId !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(missionId)) {
    return json({ error: "mission_id must be a UUID" }, 422);
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const user = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: userData, error: userError } = await user.auth.getUser();
  if (userError || !userData?.user) return json({ error: "Invalid or expired session" }, 401);

  // The database derives the actor from auth.uid(). No service-role call accepts a caller-supplied actor UUID.
  const { data: result, error: cancelError } = await user.rpc("aios_cancel_mission", {
    p_mission_id: missionId,
  });
  if (cancelError) {
    const status = cancelError.code === "42501" ? 403 : cancelError.code === "40001" ? 409 : 500;
    return json({ error: "Mission cancellation failed" }, status);
  }
  if (!result || typeof result !== "object") return json({ error: "Invalid cancellation result" }, 500);

  const outcome = (result as Record<string, unknown>).outcome;
  if (outcome === "not_found") return json({ error: "Mission not found" }, 404);
  if (outcome === "not_cancellable") return json(result, 409);
  if (outcome === "already_terminal") return json(result, 200);
  if (outcome === "cancelled") return json(result, 200);
  return json({ error: "Unknown cancellation result" }, 500);
});
