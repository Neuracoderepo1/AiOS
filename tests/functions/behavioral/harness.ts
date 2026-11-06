// Loads an Edge Function with Deno.serve captured, so tests can call its handler with real Request objects.
//
// FUNCTIONS_DIR (env) overrides where function sources are loaded from. The mutation runner uses it to point the SAME tests
// at deliberately broken copies of the functions; with it unset, the real supabase/functions directory is tested.
import { world, resetWorld, writes } from "./stubs/supabase.ts";
export { world, resetWorld, writes } from "./stubs/supabase.ts";

export function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error("assertion failed: " + msg);
}
export function eq<T>(got: T, want: T, msg: string) {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error(`${msg}: got ${JSON.stringify(got)}, wanted ${JSON.stringify(want)}`);
  }
}

type Handler = (req: Request) => Promise<Response> | Response;
const cache = new Map<string, Handler>();

export function functionsBase(): string {
  const dir = Deno.env.get("FUNCTIONS_DIR");
  if (dir) return "file://" + dir.replace(/\/+$/, "") + "/";
  return new URL("../../../supabase/functions/", import.meta.url).href;
}

export async function loadHandler(fn: string): Promise<Handler> {
  const specifier = `${functionsBase()}${fn}/index.ts`;
  if (cache.has(specifier)) return cache.get(specifier)!;
  let captured: Handler | undefined;
  const realServe = Deno.serve;
  (Deno as any).serve = (h: Handler) => {
    captured = h;
    return { finished: Promise.resolve(), shutdown: async () => {} };
  };
  try {
    await import(specifier);
  } finally {
    (Deno as any).serve = realServe;
  }
  if (!captured) throw new Error(`${fn} did not register a Deno.serve handler`);
  cache.set(specifier, captured);
  return captured;
}

// Anthropic stub: counts calls and returns whatever the test configures.
export const model = { calls: 0, text: "[]", status: 200, throwNetwork: false };
export function resetModel() {
  model.calls = 0;
  model.text = "[]";
  model.status = 200;
  model.throwNetwork = false;
}
const realFetch = globalThis.fetch;
globalThis.fetch = ((input: any, init?: any) => {
  const url = typeof input === "string" ? input : input.url;
  if (url.includes("api.anthropic.com")) {
    model.calls++;
    if (model.throwNetwork) return Promise.reject(new Error("network down"));
    return Promise.resolve(
      new Response(
        JSON.stringify({ content: [{ type: "text", text: model.text }], usage: { input_tokens: 1, output_tokens: 1 } }),
        { status: model.status, headers: { "content-type": "application/json" } },
      ),
    );
  }
  return realFetch(input, init);
}) as typeof fetch;

// console.error is captured, not printed: the functions report swallowed failures (compensation, audit, best-effort writes)
// there, and several tests assert that those failures are NOT silent.
export const errors: string[] = [];
console.error = (...a: unknown[]) => { errors.push(a.map(String).join(" ")); };

export function setEnv(opts: { anthropicKey?: string | null } = {}) {
  Deno.env.set("SUPABASE_URL", "http://stub");
  Deno.env.set("SUPABASE_ANON_KEY", "anon");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service");
  if (opts.anthropicKey === null) Deno.env.delete("ANTHROPIC_API_KEY");
  else Deno.env.set("ANTHROPIC_API_KEY", opts.anthropicKey ?? "test-key");
}
export function post(body: unknown, headers: Record<string, string> = { Authorization: "Bearer t" }) {
  return new Request("http://stub/fn", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}
export { world as _world };

// ---- test helpers -------------------------------------------------------------------------------------------------

/** Reset every piece of shared state. Call at the start of each test. */
export function fresh(tables: Record<string, any[]> = {}, opts: { anthropicKey?: string | null } = {}) {
  resetWorld(tables);
  resetModel();
  errors.length = 0;
  setEnv(opts);
}

/** Compact, ordered view of every write, e.g. ["insert aios_missions", "update aios_tasks"]. */
export function writeLog(): string[] {
  return writes().map((o) => `${o.mode} ${o.table}`);
}

export async function call(fn: string, body: unknown, headers?: Record<string, string>) {
  const h = await loadHandler(fn);
  const res = await h(post(body, headers));
  let json: any = null;
  try { json = await res.clone().json(); } catch { /* non-JSON body */ }
  return { status: res.status, json };
}

export const ORG = "org-1";

/** Tables for launch-mission: one eligible Research Director with exactly one active contract. */
export function launchTables(): Record<string, any[]> {
  return {
    aios_agents: [{ id: "agent-1", organization_id: ORG, role: "Research Director", status: "active", authority: { allowed_tools: ["support.search_tickets"] } }],
    aios_contracts: [{ id: "contract-1", agent_id: "agent-1", organization_id: ORG, version: 1, is_active: true, allowed_tools: ["support.search_tickets"] }],
  };
}
export const LAUNCH_BODY = { organization_id: ORG, title: "Quarterly research", objective: "Survey the competitive landscape" };
export const planJson = (tasks: unknown[]) => JSON.stringify(tasks);
export const okTask = (risk_level: unknown = "low", extra: Record<string, unknown> = {}) => ({ title: "Task", instructions: "Do the thing", risk_level, ...extra });

/** Tables for execute-task: one queued task on a queued mission with an active agent. */
export function executeTables(over: { task?: Record<string, unknown>; mission?: Record<string, unknown> } = {}): Record<string, any[]> {
  return {
    aios_tasks: [{ id: "task-1", organization_id: ORG, mission_id: "mission-1", assigned_agent_id: "agent-1", title: "Find top problems", instructions: "Analyse support tickets", status: "queued", risk_level: "low", result: null, ...over.task }],
    aios_missions: [{ id: "mission-1", organization_id: ORG, status: "queued", ...over.mission }],
    aios_agents: [{ id: "agent-1", name: "Atlas", role: "Research Director", primary_model: "claude-sonnet-4-6", status: "active", authority: { allowed_tools: ["support.search_tickets"] } }],
  };
}
