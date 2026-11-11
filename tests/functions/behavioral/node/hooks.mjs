// Node module-resolution hook that applies the SAME import_map.json Deno would use. A jsr:/npm: specifier that the map does
// not list is a hard error here (Deno would try the network), so a missing mapping can never pass silently.
import { readFileSync } from "node:fs";
import { dirname, resolve as resolvePath } from "node:path";
import { pathToFileURL } from "node:url";

let map = {};

export async function initialize({ importMapPath }) {
  const base = dirname(importMapPath);
  const imports = JSON.parse(readFileSync(importMapPath, "utf8")).imports ?? {};
  map = Object.fromEntries(Object.entries(imports).map(([k, v]) => [k, pathToFileURL(resolvePath(base, v)).href]));
}

export async function resolve(specifier, context, nextResolve) {
  if (Object.prototype.hasOwnProperty.call(map, specifier)) return { url: map[specifier], shortCircuit: true };
  if (specifier.startsWith("jsr:") || specifier.startsWith("npm:")) {
    throw new Error(`import map does not resolve "${specifier}"`);
  }
  return nextResolve(specifier, context);
}
