// Fake @supabase/supabase-js for behavioral tests. Records every database operation in order so tests can assert on
// WHAT was written and WHEN, not just on source text. The world is a module-level singleton reset by each test.
//
// THIS IS A TEST DOUBLE, NOT POSTGRESQL. It can verify operation order and handler responses. It cannot establish real
// transaction atomicity, trigger behaviour, RLS enforcement, or production concurrency guarantees.
//
// Written with erasable TypeScript only (no parameter properties, no enums) so it also runs under Node type-stripping.
export interface Op {
  client: "user" | "admin";
  table: string;
  mode: "select" | "insert" | "update" | "delete";
  rows?: any[];
  patch?: any;
  filters: Array<[string, string, unknown]>;
}
export interface World {
  tables: Record<string, any[]>;
  ops: Op[];
  rpcs: Array<{ name: string; args: unknown }>;
  fail: Record<string, string>; // "table:mode" -> error message returned for EVERY such operation
  validSession: boolean;
  isMember: boolean;
  // Called at the start of every operation, before it is applied. Lets a test change the world "between" a handler's read
  // and its next write (for example to simulate another execution winning a task claim).
  onOp: ((op: Op) => void) | null;
}
export const world: World = { tables: {}, ops: [], rpcs: [], fail: {}, validSession: true, isMember: true, onOp: null };
export function resetWorld(tables: Record<string, any[]> = {}) {
  world.tables = structuredClone(tables);
  world.ops = [];
  world.rpcs = [];
  world.fail = {};
  world.validSession = true;
  world.isMember = true;
  world.onOp = null;
}
export const writes = () => world.ops.filter((o) => o.mode !== "select");

const UNSUPPORTED = ["limit", "or", "gte", "lte", "order", "in", "is", "gt", "lt", "ilike", "like", "not", "upsert"];

class Query {
  client: "user" | "admin";
  table: string;
  mode: Op["mode"] = "select";
  rows: any[] = [];
  patch: any = undefined;
  filters: Op["filters"] = [];
  returning = false;
  one: "single" | "maybe" | null = null;
  constructor(client: "user" | "admin", table: string) {
    this.client = client;
    this.table = table;
    // Fail loudly instead of silently ignoring a filter the stub does not model.
    for (const m of UNSUPPORTED) {
      (this as any)[m] = () => { throw new Error(`stub: query method .${m}() is not modelled`); };
    }
  }
  select(_cols?: string) { if (this.mode !== "select") this.returning = true; return this; }
  insert(rows: any) { this.mode = "insert"; this.rows = Array.isArray(rows) ? rows : [rows]; return this; }
  update(patch: any) { this.mode = "update"; this.patch = patch; return this; }
  delete() { this.mode = "delete"; return this; }
  eq(c: string, v: unknown) { this.filters.push(["eq", c, v]); return this; }
  neq(c: string, v: unknown) { this.filters.push(["neq", c, v]); return this; }
  single() { this.one = "single"; return this; }
  maybeSingle() { this.one = "maybe"; return this; }
  then(res: (v: any) => any, rej?: (e: any) => any) {
    try { return Promise.resolve(this.exec()).then(res, rej); } catch (e) { return Promise.reject(e).then(res, rej); }
  }
  match(r: any) { return this.filters.every(([op, c, v]) => (op === "eq" ? r[c] === v : r[c] !== v)); }
  exec() {
    const op: Op = {
      client: this.client,
      table: this.table,
      mode: this.mode,
      rows: this.rows.length ? this.rows : undefined,
      patch: this.patch,
      filters: this.filters,
    };
    world.ops.push(op);
    if (world.onOp) world.onOp(op);
    const failMsg = world.fail[`${this.table}:${this.mode}`];
    if (failMsg) return { data: null, error: { message: failMsg } };
    const t = (world.tables[this.table] ??= []);
    let data: any[] | null;
    if (this.mode === "insert") {
      const inserted = this.rows.map((r) => ({ id: crypto.randomUUID(), ...r }));
      t.push(...inserted);
      data = this.returning ? inserted : null;
    } else if (this.mode === "update") {
      const hit = t.filter((r) => this.match(r));
      hit.forEach((r) => Object.assign(r, this.patch));
      data = this.returning ? hit : null;
    } else if (this.mode === "delete") {
      world.tables[this.table] = t.filter((r) => !this.match(r));
      data = null;
    } else {
      data = t.filter((r) => this.match(r));
    }
    if (this.one && data) data = [data[0] ?? null] as any;
    return { data: this.one && data ? data[0] : data, error: null };
  }
}

export function createClient(_url: string, _key: string, opts?: { global?: { headers?: Record<string, string> } }) {
  const isUser = !!opts?.global?.headers?.Authorization;
  const client = isUser ? "user" : "admin";
  return {
    auth: {
      getUser: async () =>
        world.validSession
          ? { data: { user: { id: "user-1" } }, error: null }
          : { data: { user: null }, error: { message: "invalid" } },
    },
    rpc: async (name: string, args: unknown) => {
      world.rpcs.push({ name, args });
      return { data: name === "aios_is_org_member" ? world.isMember : null, error: null };
    },
    from: (table: string) => new Query(client, table),
  };
}
