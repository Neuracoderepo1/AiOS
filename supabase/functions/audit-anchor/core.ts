// Part E (E04/E05): external audit-anchoring service core. Pure logic with injected dependencies (no network, no secrets here).
// Trust boundary: this service obtains the canonical head, builds the checkpoint, asks an EXTERNAL anchor adapter to produce AND READ BACK
// verify independent evidence, and only then submits it to the database, which re-validates the exact (count, head id, hash, timestamp)
// binding. The database never treats the submission as proof of authenticity; tools/audit-verify re-verifies cryptographically in CI.
// This service has NO ability to modify audit events: it only calls the four service_role wrappers listed in Rpc below.

export interface Head { organization_id: string; event_count: number; head_id: string; head_hash: string; head_at: string }
export interface Checkpoint extends Head { text: string; digest: string }
export interface AdapterResult { artifact_sha256: string; artifact_ref: string; evidence: Record<string, unknown> }
export interface AnchorAdapter { readonly type: "git" | "rfc3161"; submit(cp: Checkpoint): Promise<AdapterResult> }
export interface Rpc { call(fn: "aios_audit_heads" | "aios_audit_chain_export" | "aios_audit_anchors_list" | "aios_audit_record_anchor", args: Record<string, unknown>): Promise<any> }
export interface Deps { rpc: Rpc; adapters: AnchorAdapter[]; log: (e: Record<string, unknown>) => void }

/** An external dependency (TSA, trust roots, repository credentials) is not configured. Reported as BLOCKED, never as success. */
export class ExternalDependencyBlocked extends Error {}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HEX64 = /^[0-9a-f]{64}$/;
export const MAX_BODY_BYTES = 4096;

export async function sha256Hex(s: string | Uint8Array): Promise<string> {
  const data: Uint8Array<ArrayBuffer> = typeof s === "string" ? new TextEncoder().encode(s) as Uint8Array<ArrayBuffer> : new Uint8Array(s);
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", data))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Database export timestamps are jsonb text ('...+00:00', trailing zeros trimmed); checkpoints use fixed 6-digit microseconds and 'Z'. */
export function headAtZ(iso: string): string {
  const m = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?\+00:00$/.exec(iso);
  if (!m) throw new Error("non-UTC or malformed head_at");
  return `${m[1]}.${((m[2] ?? ".").slice(1) + "000000").slice(0, 6)}Z`;
}

export function checkpointText(h: Head): string {
  return ["aios-audit-checkpoint-v1", h.organization_id, String(h.event_count), h.head_id, h.head_hash, headAtZ(h.head_at)].join("\n");
}

export async function buildCheckpoint(h: Head): Promise<Checkpoint> {
  if (!UUID.test(h.organization_id) || !UUID.test(h.head_id) || !HEX64.test(h.head_hash) || !Number.isInteger(h.event_count) || h.event_count < 1) throw new Error("invalid head");
  const text = checkpointText(h);
  return { ...h, text, digest: await sha256Hex(text) };
}

/** Constant-time comparison for the invocation secret. */
export function timingSafeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

export interface Request { organization_id?: string; evidence_type?: "git" | "rfc3161" }
export function parseRequest(raw: string): Request {
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) throw new HttpError(413, "body too large");
  let j: any;
  try { j = raw.trim() === "" ? {} : JSON.parse(raw); } catch { throw new HttpError(400, "invalid JSON"); }
  if (typeof j !== "object" || j === null || Array.isArray(j)) throw new HttpError(400, "body must be an object");
  for (const k of Object.keys(j)) if (k !== "organization_id" && k !== "evidence_type") throw new HttpError(400, `unknown field ${k}`);
  if (j.organization_id !== undefined && !(typeof j.organization_id === "string" && UUID.test(j.organization_id))) throw new HttpError(400, "organization_id must be a lowercase uuid");
  if (j.evidence_type !== undefined && j.evidence_type !== "git" && j.evidence_type !== "rfc3161") throw new HttpError(400, "evidence_type must be git or rfc3161");
  return j;
}
export class HttpError extends Error { constructor(public status: number, msg: string) { super(msg); } }

export type OrgOutcome = { organization_id: string; adapter: string; status: "anchored" | "already_anchored" | "BLOCKED_EXTERNAL_DEPENDENCY" | "refused" | "error"; detail?: string; event_count?: number };

export async function anchorOnce(deps: Deps, head: Head, adapter: AnchorAdapter): Promise<OrgOutcome> {
  const base = { organization_id: head.organization_id, adapter: adapter.type, event_count: head.event_count };
  try {
    // 1. skip when this exact position is already anchored with this evidence type (safe retries; idempotent at the DB too)
    const existing: any[] = await deps.rpc.call("aios_audit_anchors_list", { p_organization_id: head.organization_id });
    if (existing.some((a) => a.evidence_type === adapter.type && Number(a.event_count) >= head.event_count)) return { ...base, status: "already_anchored" };
    // 2. bind to the EXACT event: re-read the event at the head position and compare id / hash / timestamp (guards against a head that moved or was altered)
    const page = await deps.rpc.call("aios_audit_chain_export", { p_organization_id: head.organization_id, p_after_count: head.event_count - 1, p_limit: 1 });
    const ev = page?.events?.[0];
    if (!ev || ev.id !== head.head_id || ev.event_hash !== head.head_hash || ev.created_at !== head.head_at || Number(ev.seq) !== head.event_count) {
      return { ...base, status: "refused", detail: "head does not match the event at that position" };
    }
    const cp = await buildCheckpoint(head);
    // 3. external evidence (the adapter must read back / verify its own artifact before returning)
    const res = await adapter.submit(cp);
    if (!HEX64.test(res.artifact_sha256)) throw new Error("adapter returned a malformed artifact digest");
    // 4. submit to the database, which re-validates count/head/timestamp and the evidence-to-checkpoint binding
    await deps.rpc.call("aios_audit_record_anchor", {
      p_organization_id: head.organization_id, p_event_count: head.event_count, p_head_event_id: head.head_id, p_head_hash: head.head_hash, p_head_at: head.head_at,
      p_evidence_type: adapter.type, p_artifact_sha256: res.artifact_sha256, p_artifact_ref: res.artifact_ref, p_evidence: res.evidence,
    });
    return { ...base, status: "anchored" };
  } catch (e) {
    if (e instanceof ExternalDependencyBlocked) return { ...base, status: "BLOCKED_EXTERNAL_DEPENDENCY", detail: e.message };
    return { ...base, status: "error", detail: e instanceof Error ? e.message.slice(0, 200) : "unknown" };
  }
}

export async function run(deps: Deps, req: Request): Promise<{ results: OrgOutcome[]; overall: "ANCHORED" | "BLOCKED" | "PARTIAL_FAILURE" | "NOTHING_TO_DO" }> {
  const heads: Head[] = (await deps.rpc.call("aios_audit_heads", {})) ?? [];
  const adapters = deps.adapters.filter((a) => !req.evidence_type || a.type === req.evidence_type);
  const results: OrgOutcome[] = [];
  for (const h of heads.filter((x) => !req.organization_id || x.organization_id === req.organization_id)) {
    for (const a of adapters) {
      const r = await anchorOnce(deps, h, a);
      deps.log({ event: "anchor", ...r });
      results.push(r);
    }
  }
  const bad = results.some((r) => r.status === "error" || r.status === "refused");
  const blocked = results.some((r) => r.status === "BLOCKED_EXTERNAL_DEPENDENCY");
  const ok = results.some((r) => r.status === "anchored" || r.status === "already_anchored");
  // an outage or missing dependency is NEVER reported as success
  return { results, overall: bad ? "PARTIAL_FAILURE" : blocked ? "BLOCKED" : ok ? "ANCHORED" : "NOTHING_TO_DO" };
}
