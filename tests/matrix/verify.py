#!/usr/bin/env python3
"""Verify executed matrix results against tests/matrix/manifest.json (the canonical definition).

Fails (exit 1) on ANY drift: a case missing, extra, duplicated, renamed, moved to another domain, failing, or a G4 check
missing/failing/out of order. A green matrix therefore means exactly the 46 canonical cases ran and passed.

Usage: verify.py --manifest M --sql-log LOG --g4-log LOG [--report OUT.json]
"""
import argparse, json, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("--manifest", required=True)
ap.add_argument("--sql-log", required=True)
ap.add_argument("--g4-log", required=True)
ap.add_argument("--report")
a = ap.parse_args()

man = json.load(open(a.manifest))
errors, results = [], {}

# ---- SQL cases: MX_RESULT|id|domain|PASS/FAIL|detail   (detail may itself contain '|')
seen = []
for line in open(a.sql_log, errors="replace"):
    if not line.startswith("MX_RESULT|"):
        continue
    parts = line.rstrip("\n").split("|", 4)
    if len(parts) < 4:
        errors.append(f"malformed result line: {line.strip()[:120]}")
        continue
    _, cid, domain, status = parts[:4]
    detail = parts[4] if len(parts) > 4 else ""
    seen.append(cid)
    if cid in results:
        errors.append(f"{cid}: reported more than once")
    results[cid] = {"domain": domain, "status": status, "detail": detail}

want = {c["id"]: c for c in man["cases"]}
for cid in sorted(set(want) - set(results)):
    errors.append(f"{cid}: in manifest but NOT executed")
for cid in sorted(set(results) - set(want)):
    errors.append(f"{cid}: executed but NOT in manifest")
for cid, r in results.items():
    if cid in want:
        if r["domain"] != want[cid]["domain"]:
            errors.append(f"{cid}: domain '{r['domain']}' != manifest '{want[cid]['domain']}'")
        if r["status"] != "PASS":
            errors.append(f"{cid}: {r['status']} -- {r['detail']}")
if len(results) != man["sql_cases"]:
    errors.append(f"expected {man['sql_cases']} SQL cases, executed {len(results)}")

# ---- G4: ordered PASS/FAIL check lines, each must match the manifest's check in order
checks = []
for line in open(a.g4_log, errors="replace"):
    m = re.match(r"^\s+(PASS|FAIL) (.*)$", line.rstrip("\n"))
    if m:
        checks.append((m.group(1), m.group(2)))
g4 = man["g4"]["checks"]
if len(checks) != len(g4):
    errors.append(f"G4: expected {len(g4)} checks, found {len(checks)}")
for i, spec in enumerate(g4):
    if i >= len(checks):
        errors.append(f"G4 {spec['scenario']}: missing check '{spec['match']}'")
        continue
    st, text = checks[i]
    if not text.startswith(spec["match"]):
        errors.append(f"G4 {spec['scenario']}: check #{i+1} is '{text[:70]}', expected '{spec['match']}...'")
    if st != "PASS":
        errors.append(f"G4 {spec['scenario']}: FAIL -- {text}")
g4_text = open(a.g4_log, errors="replace").read()
if "ok: G4 eight-way concurrency" not in g4_text:
    errors.append("G4: success marker 'ok: G4 eight-way concurrency' not present")

# ---- report
per_domain = {d: {"expected": n, "passed": 0} for d, n in man["domain_counts"].items()}
for cid, r in results.items():
    if r["status"] == "PASS" and r["domain"] in per_domain and cid in want:
        per_domain[r["domain"]]["passed"] += 1
g4d = man["g4"]["domain"]
if "ok: G4 eight-way concurrency" in g4_text and all(st == "PASS" for st, _ in checks) and len(checks) == len(g4):
    per_domain[g4d]["passed"] += 1
total_pass = sum(v["passed"] for v in per_domain.values())
report = {"manifest_total": man["total_cases"], "passed": total_pass, "g4_checks": len(checks),
          "per_domain": per_domain, "errors": errors, "ok": not errors and total_pass == man["total_cases"]}
if a.report:
    json.dump(report, open(a.report, "w"), indent=2)

print("AiOS canonical matrix")
for d, v in per_domain.items():
    print(f"  {d:<30} {v['passed']}/{v['expected']}")
print(f"  {'TOTAL':<30} {total_pass}/{man['total_cases']}   (G4 checks: {len(checks)}/{len(g4)})")
if errors:
    print("DRIFT/FAILURES:")
    for e in errors:
        print("  -", e)
    sys.exit(1)
if total_pass != man["total_cases"]:
    print("  - passed count != manifest total"); sys.exit(1)
print("ok: canonical matrix verified (46/46)")
