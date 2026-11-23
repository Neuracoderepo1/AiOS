#!/usr/bin/env python3
"""Static security checks for Part D/E (fail-closed). Complements, never replaces, the runtime suites.
 S1 a pinned function (verifier, canonical hash, drift check, ...) may be defined in exactly ONE migration (later CREATE OR REPLACE = weakening risk)
 S2 every SECURITY DEFINER function in Part D/E pins search_path = ''
 S3 no GRANT to anon/authenticated/PUBLIC anywhere in Part D/E; EXECUTE for service_role only on public.aios_audit_* wrappers
 S4 no JWT-claim based authorization in restoration code
 S5 no logging statements (RAISE NOTICE/LOG/WARNING) in Part D/E that could echo credentials
 S6 Edge Function never logs secret-bearing variables
"""
import glob, os, re, sys
ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
MIG = sorted(glob.glob(os.path.join(ROOT, "supabase", "migrations", "*.sql")))
D = [m for m in MIG if m.endswith("_aios_restoration_part_d.sql")]; E = [m for m in MIG if m.endswith("_aios_audit_anchoring_part_e.sql")]
errs = []
PINNED = ["aios_final_verify", "aios_guard_drift", "aios_audit_canonical_payload", "aios_audit_canonical_hash", "aios_audit_verify_chain_v2", "aios_audit_record_anchor", "aios_audit_checkpoint_text", "aios_scheduled_verify"]

if len(D) != 1 or len(E) != 1: errs.append("expected exactly one Part D and one Part E migration, found %d/%d" % (len(D), len(E)))
for fn in PINNED:
    definers = [os.path.basename(m) for m in MIG if re.search(r"create\s+(or\s+replace\s+)?function\s+private\.%s\s*\(" % fn, open(m).read(), re.I)]
    if len(definers) != 1: errs.append("S1 %s is defined in %d migrations (%s): a later definition could silently weaken it" % (fn, len(definers), ", ".join(definers)))
    # a later migration must not touch it either (ALTER FUNCTION ... SET/OWNER, DROP FUNCTION)
    for m in MIG:
        t = open(m).read()
        if os.path.basename(m) not in definers and re.search(r"(alter|drop)\s+function\s+private\.%s\b" % fn, t, re.I): errs.append("S1 %s is altered/dropped by %s" % (fn, os.path.basename(m)))

for m in D + E:
    t = open(m).read(); name = os.path.basename(m)
    for hdr in re.finditer(r"create\s+(?:or\s+replace\s+)?function\s+([\w.]+)\s*\((.*?)\)\s*(returns.*?)\bas\s+\$", t, re.I | re.S):
        head = hdr.group(0)
        if re.search(r"security\s+definer", head, re.I) and not re.search(r"set\s+search_path\s*=\s*''", head, re.I):
            errs.append("S2 %s: SECURITY DEFINER function %s does not pin search_path = ''" % (name, hdr.group(1)))
    for g in re.finditer(r"\bgrant\b[^;]*?\bto\b([^;]*);", t, re.I | re.S):
        who = g.group(1).lower()
        if re.search(r"\b(anon|authenticated|public)\b", who): errs.append("S3 %s: grant to anon/authenticated/public: %s" % (name, g.group(0)[:120].replace("\n", " ")))
        if "service_role" in who and not re.search(r"public\.aios_audit_", g.group(0)): errs.append("S3 %s: service_role grant outside the public.aios_audit_* wrappers: %s" % (name, g.group(0)[:120].replace("\n", " ")))
    body = re.sub(r"--[^\n]*", "", t)
    if re.search(r"request\.jwt|auth\.jwt\(|auth\.role\(|current_setting\('request", body, re.I): errs.append("S4 %s: JWT-claim based authorization is forbidden" % name)
    if re.search(r"raise\s+(notice|log|warning|info|debug)", body, re.I): errs.append("S5 %s: RAISE NOTICE/LOG/WARNING is not allowed (could echo credentials)" % name)

for f in glob.glob(os.path.join(ROOT, "supabase", "functions", "audit-anchor", "*.ts")):
    if f.endswith("_test.ts"): continue
    t = open(f).read()
    for m in re.finditer(r"console\.(log|error|warn|info)\(([^;]*)\)", t):
        if re.search(r"(secret|token|SERVICE_ROLE|key|authorization)", m.group(2), re.I) and "error: e instanceof Error" not in m.group(2):
            errs.append("S6 %s logs a secret-bearing expression: %s" % (os.path.basename(f), m.group(0)[:100]))
    if re.search(r"service_role|SERVICE_ROLE_KEY", t) and "authorization:" in t and f.endswith("core.ts"): errs.append("S6 core.ts must not handle credentials")

print("\n".join("FAIL " + e for e in errs) if errs else "static checks S1-S6: PASS")
sys.exit(1 if errs else 0)
