// Node fallback runner. Prints Deno-style "name ... ok|FAILED" lines so tooling can parse either runtime identically.
// Usage: node --no-warnings tests/functions/behavioral/node/run.mjs [--filter=text]
import { tests } from "./register.mjs";
import { readdirSync } from "node:fs";

const filter = process.argv.find((a) => a.startsWith("--filter="))?.slice("--filter=".length);
const dir = new URL("../", import.meta.url);
const files = readdirSync(dir).filter((f) => f.endsWith("_test.ts")).sort();
for (const f of files) await import(new URL(f, dir).href);

const selected = tests.filter((t) => !filter || t.name.includes(filter));
let passed = 0;
const failed = [];
for (const t of selected) {
  const t0 = Date.now();
  try {
    await t.fn();
    passed++;
    console.log(`${t.name} ... ok (${Date.now() - t0}ms)`);
  } catch (e) {
    failed.push(t.name);
    console.log(`${t.name} ... FAILED (${Date.now() - t0}ms)`);
    console.log(`    ${String(e?.message ?? e).split("\n").join("\n    ")}`);
  }
}
console.log(`\n${failed.length ? "FAILED" : "ok"} | ${passed} passed | ${failed.length} failed | ${selected.length} total`);
if (selected.length === 0) { console.log("no tests selected"); process.exit(2); }
process.exit(failed.length ? 1 : 0);
