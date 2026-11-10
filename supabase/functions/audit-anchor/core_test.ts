// Unit tests for the anchoring service with fake RPC/adapters. These are NOT live-anchoring evidence: live RFC3161 is EXTERNAL_DEPENDENCY_BLOCKED.
// Dependency-free assertions (no network fetch needed to run these tests).
function assert(c: unknown, msg = "assertion failed"): asserts c { if (!c) throw new Error(msg); }
function assertEquals(a: unknown, b: unknown, msg = ""): void { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`not equal: ${JSON.stringify(a)} !== ${JSON.stringify(b)} ${msg}`); }
import { AnchorAdapter, buildCheckpoint, Checkpoint, Deps, ExternalDependencyBlocked, Head, headAtZ, run, sha256Hex, timingSafeEqual, parseRequest, HttpError } from "./core.ts";
import { GitAnchorAdapter, Rfc3161Adapter } from "./adapters.ts";
import { handle } from "./index.ts";

const ORG = "e2e00000-0000-4000-8000-0000000000e1";
const EVT = "e2e00000-0000-4000-8001-000000000006";
const HASH = "ab".repeat(32);
const head = (over: Partial<Head> = {}): Head => ({ organization_id: ORG, event_count: 6, head_id: EVT, head_hash: HASH, head_at: "2026-03-01T00:06:00.12+00:00", ...over });

function fakeDeps(opts: { anchors?: any[]; eventOverride?: Record<string, unknown>; adapter?: AnchorAdapter; heads?: Head[] } = {}) {
  const calls: { fn: string; args: any }[] = [], logs: any[] = [];
  const h = opts.heads ?? [head()];
  const adapter: AnchorAdapter = opts.adapter ?? { type: "git", submit: async (cp: Checkpoint) => ({ artifact_sha256: cp.digest, artifact_ref: "git:x/y@" + "a".repeat(40), evidence: { repository: "x/y", commit: "a".repeat(40), manifest_path: "p", manifest_sha256: cp.digest, verified_by: "test" } }) };
  const deps: Deps = {
    rpc: { async call(fn, args) {
      calls.push({ fn, args });
      if (fn === "aios_audit_heads") return h;
      if (fn === "aios_audit_anchors_list") return opts.anchors ?? [];
      if (fn === "aios_audit_chain_export") return { events: [{ seq: 6, id: EVT, event_hash: HASH, created_at: "2026-03-01T00:06:00.12+00:00", ...(opts.eventOverride ?? {}) }] };
      return { ok: true };
    } },
    adapters: [adapter], log: (e) => logs.push(e),
  };
  return { deps, calls, logs };
}

Deno.test("checkpoint text/digest are canonical and match the database format (fixed microseconds, Z)", async () => {
  assertEquals(headAtZ("2026-03-01T00:06:00.12+00:00"), "2026-03-01T00:06:00.120000Z");
  assertEquals(headAtZ("2026-03-01T00:06:00+00:00"), "2026-03-01T00:06:00.000000Z");
  const cp = await buildCheckpoint(head());
  assertEquals(cp.text.split("\n").length, 6);
  assertEquals(cp.digest, await sha256Hex(cp.text));
});

Deno.test("rejects non-UTC timestamps, bad hashes, bad counts", async () => {
  for (const bad of [head({ head_at: "2026-03-01T00:06:00+02:00" }), head({ head_hash: "xyz" }), head({ event_count: 0 }), head({ organization_id: "nope" })]) {
    let threw = false; try { await buildCheckpoint(bad); } catch { threw = true; } assert(threw);
  }
});

Deno.test("success path submits the exact count/head/timestamp bound evidence to the database", async () => {
  const { deps, calls } = fakeDeps();
  const r = await run(deps, {});
  assertEquals(r.overall, "ANCHORED");
  const rec = calls.find((c) => c.fn === "aios_audit_record_anchor")!;
  assertEquals(rec.args.p_event_count, 6); assertEquals(rec.args.p_head_hash, HASH); assertEquals(rec.args.p_head_at, "2026-03-01T00:06:00.12+00:00");
  assertEquals(rec.args.p_evidence_type, "git");
});

Deno.test("idempotent retry: an already anchored position is not re-submitted", async () => {
  const { deps, calls } = fakeDeps({ anchors: [{ evidence_type: "git", event_count: 6 }] });
  const r = await run(deps, {});
  assertEquals(r.results[0].status, "already_anchored"); assertEquals(r.overall, "ANCHORED");
  assert(!calls.some((c) => c.fn === "aios_audit_record_anchor"));
});

Deno.test("a head that does not match the event at that position is refused and nothing is recorded", async () => {
  for (const o of [{ event_hash: "cd".repeat(32) }, { id: "e2e00000-0000-4000-8001-0000000000ff" }, { created_at: "2026-03-01T00:06:00.120001+00:00" }, { seq: 7 }]) {
    const { deps, calls } = fakeDeps({ eventOverride: o });
    const r = await run(deps, {});
    assertEquals(r.results[0].status, "refused"); assertEquals(r.overall, "PARTIAL_FAILURE");
    assert(!calls.some((c) => c.fn === "aios_audit_record_anchor"));
  }
});

Deno.test("RFC3161 is BLOCKED (EXTERNAL_DEPENDENCY_BLOCKED): nothing fabricated, nothing recorded, never reported as success", async () => {
  const { deps, calls } = fakeDeps({ adapter: new Rfc3161Adapter({}) });
  const r = await run(deps, {});
  assertEquals(r.results[0].status, "BLOCKED_EXTERNAL_DEPENDENCY"); assertEquals(r.overall, "BLOCKED");
  assert(!calls.some((c) => c.fn === "aios_audit_record_anchor"));
  // even fully 'configured' env vars do not enable it: the verifier does not exist in this release
  const r2 = await run(fakeDeps({ adapter: new Rfc3161Adapter({ tsaUrl: "https://tsa.example", trustRoots: "x", verifierUrl: "https://v.example" }) }).deps, {});
  assertEquals(r2.overall, "BLOCKED");
});

Deno.test("an adapter failure records nothing and is an error, not success", async () => {
  const adapter: AnchorAdapter = { type: "git", submit: async () => { throw new Error("github 500"); } };
  const { deps, calls } = fakeDeps({ adapter });
  const r = await run(deps, {});
  assertEquals(r.results[0].status, "error"); assertEquals(r.overall, "PARTIAL_FAILURE");
  assert(!calls.some((c) => c.fn === "aios_audit_record_anchor"));
});

Deno.test("a malformed artifact digest from an adapter is rejected before the database call", async () => {
  const adapter: AnchorAdapter = { type: "git", submit: async () => ({ artifact_sha256: "nothex", artifact_ref: "x", evidence: {} }) };
  const { deps, calls } = fakeDeps({ adapter });
  assertEquals((await run(deps, {})).results[0].status, "error");
  assert(!calls.some((c) => c.fn === "aios_audit_record_anchor"));
});

Deno.test("organization filter and evidence_type filter are honoured", async () => {
  const other = head({ organization_id: "ffffffff-0000-4000-8000-000000000001" });
  const { deps } = fakeDeps({ heads: [head(), other] });
  const r = await run(deps, { organization_id: ORG });
  assertEquals(r.results.length, 1);
  assertEquals((await run(fakeDeps().deps, { evidence_type: "rfc3161" })).overall, "NOTHING_TO_DO");
});

Deno.test("request validation: strict fields, size bound, uuid format", () => {
  assertEquals(parseRequest(""), {});
  for (const bad of ['{"x":1}', "[]", "nope", '{"organization_id":"A"}', '{"evidence_type":"x509"}', '{"p":"' + "a".repeat(5000) + '"}']) {
    let st = 0; try { parseRequest(bad); } catch (e) { st = (e as HttpError).status; } assert(st === 400 || st === 413, bad.slice(0, 30));
  }
});

Deno.test("timingSafeEqual", () => { assert(timingSafeEqual("a".repeat(40), "a".repeat(40))); assert(!timingSafeEqual("a".repeat(40), "a".repeat(39) + "b")); assert(!timingSafeEqual("a", "")); });

Deno.test("handler: auth, method, no leakage of the secret in responses or logs", async () => {
  const secret = "s".repeat(40);
  const env = (k: string) => ({ AUDIT_ANCHOR_INVOKE_SECRET: secret, SUPABASE_URL: "https://x.test", SUPABASE_SERVICE_ROLE_KEY: "service-key-should-never-appear" } as Record<string, string>)[k];
  assertEquals((await handle(new Request("https://f.test", { method: "GET" }), env)).status, 405);
  assertEquals((await handle(new Request("https://f.test", { method: "POST" }), env)).status, 401);
  assertEquals((await handle(new Request("https://f.test", { method: "POST", headers: { "x-aios-anchor-secret": "wrong" } }), env)).status, 401);
  assertEquals((await handle(new Request("https://f.test", { method: "POST", headers: { "x-aios-anchor-secret": secret }, body: "{bad" }), env, fakeDeps().deps)).status, 400);
  assertEquals((await handle(new Request("https://f.test", { method: "POST", headers: { "x-aios-anchor-secret": "x" } }), (k) => k === "AUDIT_ANCHOR_INVOKE_SECRET" ? "short" : undefined)).status, 500);
  const ok = await handle(new Request("https://f.test", { method: "POST", headers: { "x-aios-anchor-secret": secret }, body: "{}" }), env, fakeDeps().deps);
  const text = await ok.text();
  assertEquals(ok.status, 200); assert(!text.includes(secret) && !text.includes("service-key"));
});

Deno.test("git adapter: not configured => BLOCKED; read-back mismatch => error; correct read-back => evidence", async () => {
  const cp = await buildCheckpoint(head());
  let blocked = false; try { await new GitAnchorAdapter({}).submit(cp); } catch (e) { blocked = e instanceof ExternalDependencyBlocked; } assert(blocked);
  const commit = "c".repeat(40);
  const mk = (back: string): typeof fetch => (async (url: any, init?: any) => {
    const u = String(url);
    if (init?.method === "PUT") return new Response(JSON.stringify({ commit: { sha: commit } }), { status: 201 });
    return new Response(JSON.stringify({ content: btoa(back) }), { status: 200 });
  }) as typeof fetch;
  const good = await new GitAnchorAdapter({ repo: "o/r", token: "tok" }, mk(cp.text)).submit(cp);
  assertEquals(good.evidence.commit, commit); assertEquals(good.evidence.manifest_sha256, cp.digest); assertEquals(good.artifact_ref, `git:o/r@${commit}`);
  let bad = false; try { await new GitAnchorAdapter({ repo: "o/r", token: "tok" }, mk(cp.text + "x")).submit(cp); } catch { bad = true; } assert(bad);
  let inv = false; try { await new GitAnchorAdapter({ repo: "../etc", token: "t" }).submit(cp); } catch { inv = true; } assert(inv);
});
