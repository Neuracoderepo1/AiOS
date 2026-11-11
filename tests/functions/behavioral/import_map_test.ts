// The import map must resolve EVERY external specifier the Edge Functions import, or the behavioral tests would silently be
// exercising something other than what production loads. This scans the real sources rather than trusting a hand-kept list.
import { assert, loadHandler, functionsBase } from "./harness.ts";

const SPEC = /(?:^|\n)\s*import\s+(?:[^"';]*?\s+from\s+)?["']([^"']+)["']/g;
const mapUrl = new URL("./import_map.json", import.meta.url);

function importSpecifiers(source: string): string[] {
  return [...source.matchAll(SPEC)].map((m) => m[1]);
}

Deno.test("import map resolves every external import in every Edge Function", async () => {
  const imports: Record<string, string> = JSON.parse(await Deno.readTextFile(mapUrl)).imports;
  const base = new URL(functionsBase());
  const dirs: string[] = [];
  for await (const e of Deno.readDir(base)) if (e.isDirectory) dirs.push(e.name);
  assert(dirs.includes("execute-task") && dirs.includes("launch-mission"), `execute-task and launch-mission present (found ${dirs.join(",")})`);
  for (const d of dirs.sort()) {
    const source = await Deno.readTextFile(new URL(`${d}/index.ts`, base));
    // A function may import only local modules (audit-anchor does); that is valid and means no import-map entries are needed.
    const allSpecs = importSpecifiers(source);
    assert(allSpecs.length > 0, d + ": scanner found no static imports (scanner broken?)");
    const external = allSpecs.filter((s) => !s.startsWith(".") && !s.startsWith("/"));
    for (const s of external) assert(s in imports, d + " imports \"" + s + "\" but import_map.json does not map it");
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
