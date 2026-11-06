// The import map must resolve EVERY external specifier the Edge Functions import, or the behavioral tests would silently be
// exercising something other than what production loads. This scans the real sources rather than trusting a hand-kept list.
import { assert, loadHandler, functionsBase } from "./harness.ts";

const SPEC = /(?:^|\n)\s*import\s+(?:[^"';]*?\s+from\s+)?["']([^"']+)["']/g;
const mapUrl = new URL("./import_map.json", import.meta.url);

function externalSpecifiers(source: string): string[] {
  const found: string[] = [];
  for (const m of source.matchAll(SPEC)) {
    const s = m[1];
    if (!s.startsWith(".") && !s.startsWith("/")) found.push(s);
  }
  return found;
}

Deno.test("import map resolves every external import in every Edge Function", async () => {
  const imports: Record<string, string> = JSON.parse(await Deno.readTextFile(mapUrl)).imports;
  const base = new URL(functionsBase());
  const dirs: string[] = [];
  for await (const e of Deno.readDir(base)) if (e.isDirectory) dirs.push(e.name);
  assert(dirs.includes("execute-task") && dirs.includes("launch-mission"), `execute-task and launch-mission present (found ${dirs.join(",")})`);
  for (const d of dirs.sort()) {
    const source = await Deno.readTextFile(new URL(`${d}/index.ts`, base));
    const specs = externalSpecifiers(source);
    assert(specs.length > 0, `${d}: scanner found no imports (scanner broken?)`);
    for (const s of specs) assert(s in imports, `${d} imports "${s}" but import_map.json does not map it`);
  }
});

Deno.test("every import map target exists on disk", async () => {
  const imports: Record<string, string> = JSON.parse(await Deno.readTextFile(mapUrl)).imports;
  for (const [spec, target] of Object.entries(imports)) {
    const stat = await Deno.stat(new URL(target, mapUrl));
    assert(stat.isFile, `${spec} -> ${target} is not a file`);
  }
});

Deno.test("execute-task and launch-mission load under the import map and register a handler", async () => {
  for (const fn of ["execute-task", "launch-mission"]) {
    const h = await loadHandler(fn);
    assert(typeof h === "function", `${fn} handler is a function`);
  }
});
