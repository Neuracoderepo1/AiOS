#!/usr/bin/env python3
"""PostgREST glue for the external verifier workflow (stdlib only).
  fetch: paginate public.aios_audit_chain_export for every organization, plus aios_audit_anchors_list  -> <dir>/<org>.page-N.json, <org>.anchors.json
  post : after a verification, record the result via public.aios_audit_record_external_verification.
         ONLY a definite result is posted: VERIFIED (ok=true) or an integrity failure (ok=false). BLOCKED/outage posts NOTHING, so an outage ages the
         database's external-verification freshness toward anchored_unattested/FAIL instead of ever being converted into a success.
Credentials come from environment variables only: AIOS_SUPABASE_URL, AIOS_SERVICE_ROLE_KEY (never printed)."""
import argparse, hashlib, json, os, sys, urllib.request, urllib.error

PAGE = 1000


def rpc(base, key, fn, args, timeout=60):
    req = urllib.request.Request("%s/rest/v1/rpc/%s" % (base.rstrip("/"), fn), data=json.dumps(args).encode(), method="POST",
                                 headers={"apikey": key, "authorization": "Bearer " + key, "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode()
    except urllib.error.HTTPError as e:
        raise SystemExit("rpc %s failed: HTTP %s" % (fn, e.code))      # body deliberately not echoed
    except OSError as e:
        raise SystemExit("rpc %s unreachable (BLOCKED): %s" % (fn, type(e).__name__))


def fetch(base, key, out):
    os.makedirs(out, exist_ok=True)
    heads = json.loads(rpc(base, key, "aios_audit_heads", {}))
    for h in heads:
        org, after, n = h["organization_id"], 0, 1
        while True:
            raw = rpc(base, key, "aios_audit_chain_export", {"p_organization_id": org, "p_after_count": after, "p_limit": PAGE})
            pg = json.loads(raw)
            open(os.path.join(out, "%s.page-%d.json" % (org, n)), "w").write(raw)
            after += pg["returned"]; n += 1
            if not pg["has_more"] or pg["returned"] == 0: break
        open(os.path.join(out, org + ".anchors.json"), "w").write(rpc(base, key, "aios_audit_anchors_list", {"p_organization_id": org}))
    print("fetched %d organization(s)" % len(heads))
    return 0 if heads else 3


def post(base, key, report_path):
    raw = open(report_path, "rb").read(); rep = json.loads(raw); sha = hashlib.sha256(raw).hexdigest()
    if rep.get("overall") not in ("VERIFIED", "FAIL"):
        print("overall=%s: nothing posted (an outage or block is never recorded as a verification)" % rep.get("overall")); return 0
    posted = 0
    for o in rep["organizations"]:
        cps = [c for c in o.get("checkpoints", []) if c.get("result") in ("authentic", "anchor_mismatch", "truncated_history", "artifact_invalid")]
        if not cps: continue
        last = max(cps, key=lambda c: c["event_count"])
        ok = o["status"] == "verified"
        # find the matching database anchor id from the exported list
        al = json.loads(open(os.environ["AIOS_ANCHORS_DIR"] + "/" + o["organization_id"] + ".anchors.json").read())
        match = [a for a in al if int(a["event_count"]) == last["event_count"] and a["evidence_type"] == last["evidence_type"]]
        if not match: continue
        rpc(base, key, "aios_audit_record_external_verification", {"p_organization_id": o["organization_id"], "p_anchor_id": match[0]["id"], "p_event_count": last["event_count"],
            "p_head_hash": match[0]["head_hash"], "p_report_sha256": sha, "p_ok": ok, "p_details": {"status": o["status"], "verifier": rep.get("verifier")}})
        posted += 1
    print("posted %d result(s)" % posted); return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest="cmd", required=True)
    f = sp.add_parser("fetch"); f.add_argument("--out", required=True)
    p = sp.add_parser("post"); p.add_argument("--report", required=True)
    a = ap.parse_args()
    base, key = os.environ.get("AIOS_SUPABASE_URL"), os.environ.get("AIOS_SERVICE_ROLE_KEY")
    if not base or not key: print("BLOCKED: AIOS_SUPABASE_URL / AIOS_SERVICE_ROLE_KEY not configured"); sys.exit(3)
    sys.exit(fetch(base, key, a.out) if a.cmd == "fetch" else post(base, key, a.report))
