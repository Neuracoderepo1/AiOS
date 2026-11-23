// Supabase Edge Function: audit-anchor. Invoked by a scheduler (hourly) with a shared secret. POST {organization_id?, evidence_type?}.
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (injected by the platform), AUDIT_ANCHOR_INVOKE_SECRET, and the adapter variables in adapters.ts.
import { Deps, HttpError, parseRequest, run, timingSafeEqual } from "./core.ts";
import { GitAnchorAdapter, Rfc3161Adapter } from "./adapters.ts";

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export function buildDeps(env: (k: string) => string | undefined, fetcher: typeof fetch = fetch): Deps {
  const url = env("SUPABASE_URL"), key = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing");
  return {
    rpc: {
      async call(fn, args) {
        const r = await fetcher(`${url}/rest/v1/rpc/${fn}`, { method: "POST", headers: { apikey: key, authorization: `Bearer ${key}`, "content-type": "application/json" }, body: JSON.stringify(args) });
        if (!r.ok) throw new Error(`rpc ${fn} failed: ${r.status} ${(await r.text()).slice(0, 160)}`);
        return await r.json();
      },
    },
    adapters: [
      new GitAnchorAdapter({ repo: env("AUDIT_CHECKPOINT_GITHUB_REPO"), token: env("AUDIT_CHECKPOINT_GITHUB_TOKEN"), branch: env("AUDIT_CHECKPOINT_BRANCH") }, fetcher),
      new Rfc3161Adapter({ tsaUrl: env("AUDIT_TSA_URL"), trustRoots: env("AUDIT_TSA_TRUST_ROOTS_PEM"), verifierUrl: env("AUDIT_TSA_VERIFIER_URL") }),
    ],
    log: (e) => console.log(JSON.stringify({ ts: new Date().toISOString(), fn: "audit-anchor", ...e })),   // never includes secrets or tokens
  };
}

export async function handle(req: Request, env: (k: string) => string | undefined, deps?: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") return json(405, { error: "method not allowed" });
    const secret = env("AUDIT_ANCHOR_INVOKE_SECRET");
    if (!secret || secret.length < 32) return json(500, { error: "service not configured" });
    const given = req.headers.get("x-aios-anchor-secret") ?? "";
    if (!timingSafeEqual(given, secret)) return json(401, { error: "unauthorized" });
    const body = parseRequest(await req.text());
    const out = await run(deps ?? buildDeps(env), body);
    return json(out.overall === "PARTIAL_FAILURE" ? 502 : out.overall === "BLOCKED" ? 503 : 200, out);
  } catch (e) {
    if (e instanceof HttpError) return json(e.status, { error: e.message });
    console.error(JSON.stringify({ fn: "audit-anchor", error: e instanceof Error ? e.message.slice(0, 200) : "unknown" }));
    return json(500, { error: "internal error" });
  }
}

if (import.meta.main) Deno.serve((req) => handle(req, (k) => Deno.env.get(k)));
