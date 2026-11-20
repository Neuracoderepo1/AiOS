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
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const user = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: userData, error: userError } = await user.auth.getUser();
  if (userError || !userData?.user) return json({ error: "Invalid or expired session" }, 401);

  // Resolve the organization without granting the caller a service-role read path.
  const admin = createClient(url, serviceKey);
  const { data: mission, error: missionError } = await admin
    .from("aios_missions")
    .select("id,organization_id")
    .eq("id", missionId)
    .maybeSingle();
  if (missionError) return json({ error: "Mission lookup failed" }, 500);
  if (!mission) return json({ error: "Mission not found" }, 404);

  const { data: isAdmin, error: roleError } = await user.rpc("aios_is_org_admin", {
    org_id: mission.organization_id,
  });
  if (roleError) return json({ error: "Authorization check failed" }, 500);
  if (!isAdmin) return json({ error: "Only an organization owner/admin may cancel a mission" }, 403);

  // The database RPC repeats the role check under the mission row lock. This closes the lookup/authorization race.
  const { data: result, error: cancelError } = await admin.rpc("aios_cancel_mission", {
    p_mission_id: missionId,
    p_actor_user_id: userData.user.id,
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
