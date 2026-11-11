// Minimal Deno surface for running the behavioral suite under Node when Deno is not installed.
// Provides only what the harness and the functions use: Deno.serve (replaced by the harness), Deno.env, Deno.test.
import { register } from "node:module";
import { fileURLToPath } from "node:url";
import { readFile, readdir, stat } from "node:fs/promises";

const importMapPath = fileURLToPath(new URL("../import_map.json", import.meta.url));
register("./hooks.mjs", { parentURL: import.meta.url, data: { importMapPath } });

export const tests = [];

globalThis.Deno = {
  env: {
    get: (k) => process.env[k],
    set: (k, v) => { process.env[k] = String(v); },
    delete: (k) => { delete process.env[k]; },
  },
  serve: () => { throw new Error("Deno.serve was called outside the harness capture"); },
  test: (name, fn) => { tests.push({ name, fn }); },
  readTextFile: (p) => readFile(p, "utf8"),
  stat: async (p) => { const s = await stat(p); return { isFile: s.isFile(), isDirectory: s.isDirectory() }; },
  readDir: async function* (p) {
    for (const e of await readdir(p, { withFileTypes: true })) yield { name: e.name, isFile: e.isFile(), isDirectory: e.isDirectory() };
  },
};
