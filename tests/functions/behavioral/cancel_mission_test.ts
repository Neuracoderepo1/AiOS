import { assert, call, fresh, world } from "./harness.ts";

const MISSION_ID = "00000000-0000-4000-8000-000000000001";
const mission = () => world.tables.aios_missions.find((m) => m.id === MISSION_ID);
const baseMission = (status: string) => ({
  id: MISSION_ID,
  organization_id: "org-1",
  status,
  metadata: { original: "preserve-me" },
  completed_at: status === "queued" || status === "running" ? null : "2026-01-01T00:00:00Z",
});

for (const status of ["failed", "cancelled", "completed", "expired"]) {
  Deno.test(`cancel-mission: ${status} is an idempotent already_terminal no-op`, async () => {
    fresh({ aios_missions: [baseMission(status)] });
    const before = structuredClone(mission());
    const first = await call("cancel-mission", { mission_id: MISSION_ID });
    const second = await call("cancel-mission", { mission_id: MISSION_ID });
    assert(first.status === 200 && first.json.outcome === "already_terminal", "first request returns already_terminal");
    assert(second.status === 200 && second.json.outcome === "already_terminal", "repeat request returns already_terminal");
    assert(JSON.stringify(mission()) === JSON.stringify(before), "terminal mission row remains byte-for-byte unchanged");
    assert(world.rpcs.filter((r) => r.name === "aios_cancel_mission").length === 2, "both requests use the canonical database RPC");
  });
}

for (const status of ["queued", "running", "blocked_pending_approval"]) {
  Deno.test(`cancel-mission: active ${status} transitions once to cancelled`, async () => {
    fresh({ aios_missions: [baseMission(status)] });
    const first = await call("cancel-mission", { mission_id: MISSION_ID });
    const second = await call("cancel-mission", { mission_id: MISSION_ID });
    assert(first.status === 200 && first.json.outcome === "cancelled", "first request cancels");
    assert(second.status === 200 && second.json.outcome === "already_terminal", "repeat request is idempotent");
    assert(mission().status === "cancelled", "mission remains cancelled");
    assert(mission().metadata.original === "preserve-me", "existing metadata is preserved");
  });
}

Deno.test("cancel-mission: non-admin is rejected by the authenticated database RPC", async () => {
  fresh({ aios_missions: [baseMission("running")] });
  world.isAdmin = false;
  const response = await call("cancel-mission", { mission_id: MISSION_ID });
  assert(response.status === 403, "non-admin receives 403");
  assert(mission().status === "running", "mission is unchanged");
  const rpc = world.rpcs.find((r) => r.name === "aios_cancel_mission");
  assert(!!rpc, "authenticated cancellation RPC is called");
  assert(Object.keys(rpc.args as Record<string, unknown>).join(",") === "p_mission_id", "caller cannot supply or spoof actor identity");
});

Deno.test("cancel-mission: invalid mission id is rejected before database access", async () => {
  fresh({ aios_missions: [baseMission("running")] });
  const response = await call("cancel-mission", { mission_id: "not-a-uuid" });
  assert(response.status === 422, "invalid id receives 422");
  assert(world.ops.length === 0 && world.rpcs.length === 0, "no database operation occurs");
});
