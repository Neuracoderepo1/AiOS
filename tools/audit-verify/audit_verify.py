#!/usr/bin/env python3
"""AiOS independent audit verifier (Part E, E06).

Recomputes the audit hash chain WITHOUT trusting any database function, verifies externally retained checkpoints
(RFC3161 via `openssl ts -verify`; Git via repository identity + commit content), compares them with the database's
anchor list and head, and writes a machine-readable report.

Exit codes:  0 verified | 2 integrity violation | 3 BLOCKED (missing artifact / tool / trust root / outage; never success) | 1 usage

Stdlib only. Historical algorithm (migration 20260825123422; DO NOT CHANGE):
    payload    = jsonb_build_object(<19 keys>)::text || previous_event_hash       (previous_event_hash is included TWICE)
    event_hash = sha256_hex(payload)       first previous hash = 'GENESIS:' || organization_id
jsonb text form: keys ordered by (UTF-8 length, bytes); ", " and ": " separators; numbers keep their stored literal.
"""
import argparse, datetime as dt, hashlib, json, os, re, subprocess, sys

ALGO = "aios-audit-sha256-v1"
KEYS = ["id", "organization_id", "actor_user_id", "actor_type", "agent_id", "mission_id", "task_id", "invocation_id", "event_type",
        "previous_state", "new_state", "tool_name", "risk_level", "arguments_hash", "result_hash", "approval_id", "created_at", "metadata"]
HEX64 = re.compile(r"^[0-9a-f]{64}$")


class Blocked(Exception):
    """An external dependency is unavailable. Reported as BLOCKED (exit 3), never as success."""


class Num(str):
    """A JSON number kept as its original literal text (PostgreSQL jsonb preserves numeric scale)."""


def load_json(text):
    return json.loads(text, parse_float=Num, parse_int=Num)


def _key_order(k):
    b = k.encode("utf-8")
    return (len(b), b)


def jsonb_text(v):
    """Serialize exactly like PostgreSQL jsonb::text."""
    if v is None: return "null"
    if v is True: return "true"
    if v is False: return "false"
    if isinstance(v, (Num, int, float)): return str(v)     # parsed numbers are Num (literal preserved); int/float only when built by callers
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list): return "[" + ", ".join(jsonb_text(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(json.dumps(k, ensure_ascii=False) + ": " + jsonb_text(v[k]) for k in sorted(v, key=_key_order)) + "}"
    raise TypeError("unsupported JSON value %r" % (v,))


def canonical_payload(ev, prev):
    obj = {k: ev.get(k) for k in KEYS}
    obj["previous_event_hash"] = prev
    return jsonb_text(obj) + prev                      # double inclusion of previous_event_hash (historical)


def canonical_hash(ev, prev):
    return hashlib.sha256(canonical_payload(ev, prev).encode("utf-8")).hexdigest()


def checkpoint_text(org, count, head_id, head_hash, head_at):
    return "aios-audit-checkpoint-v1\n%s\n%s\n%s\n%s\n%s" % (org, count, head_id, head_hash, head_at)


def head_at_z(canonical_iso):
    """Export timestamps are PostgreSQL jsonb text ('2026-01-01T00:00:00.12+00:00'); checkpoints use fixed 6-digit microseconds + 'Z'."""
    m = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?\+00:00$", canonical_iso)
    if not m: raise ValueError("non-UTC or malformed timestamp: %r" % canonical_iso)
    return "%s.%sZ" % (m.group(1), ((m.group(2) or ".")[1:] + "000000")[:6])


def checkpoint_digest(org, count, head_id, head_hash, head_at_iso):
    return hashlib.sha256(checkpoint_text(org, count, head_id, head_hash, head_at_z(head_at_iso)).encode()).hexdigest()


# ------------------------------------------------------------------------------------------------ chain
def verify_chain(org, pages):
    """pages: export pages in order. Returns (events, summary)."""
    events, prev, problems = [], "GENESIS:" + org, []
    total = head = None
    for pg in pages:
        total, head = pg.get("total_events"), pg.get("head_hash")
        for ev in pg["events"]:
            events.append(ev)
    drift = len({(p.get("total_events"), p.get("head_hash")) for p in pages}) > 1
    for i, ev in enumerate(events, 1):
        if ev.get("seq") is not None and int(ev["seq"]) != i:
            return events, dict(valid=False, reason="seq_gap_or_duplicate", at=i, snapshot_drift=drift)
        if ev.get("previous_event_hash") != prev:
            return events, dict(valid=False, reason="previous_hash_mismatch", at=i, event_id=ev.get("id"), snapshot_drift=drift)
        if canonical_hash(ev, prev) != ev.get("event_hash"):
            return events, dict(valid=False, reason="event_hash_mismatch", at=i, event_id=ev.get("id"), snapshot_drift=drift)
        prev = ev["event_hash"]
    complete = total is not None and int(total) == len(events)
    return events, dict(valid=True, events=len(events), head_hash=(events[-1]["event_hash"] if events else None), export_complete=complete,
                        reported_total=None if total is None else int(total), snapshot_drift=drift, head_matches_reported=(head is None or not events or head == events[-1]["event_hash"] or drift))


# ------------------------------------------------------------------------------------------------ artifacts
def _run(cmd, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60, **kw)
    except FileNotFoundError as e:
        raise Blocked("required tool not found: %s" % cmd[0]) from e


def verify_rfc3161(cp, cpdir, trust_roots):
    """Cryptographic verification of the retained TSA response against the exact checkpoint text. TEST roots never count as production."""
    tsr, txt = os.path.join(cpdir, cp["artifact"]["tsr"]), os.path.join(cpdir, cp["artifact"]["checkpoint_text"])
    if not trust_roots: raise Blocked("no TSA trust roots configured (--tsa-roots)")
    if not (os.path.exists(tsr) and os.path.exists(txt)): raise Blocked("retained RFC3161 artifact missing: %s" % tsr)
    expect = hashlib.sha256(open(txt, "rb").read()).hexdigest()
    if expect != cp["checkpoint_sha256"]: return False, "checkpoint text does not match the checkpoint digest"
    r = _run(["openssl", "ts", "-verify", "-in", tsr, "-data", txt, "-CAfile", trust_roots])
    if r.returncode != 0 or "Verification: OK" not in r.stdout + r.stderr:
        return False, "openssl ts -verify failed: " + (r.stderr or r.stdout).strip()[:200]
    if hashlib.sha256(open(tsr, "rb").read()).hexdigest() != cp["artifact_sha256"]: return False, "token digest differs from the recorded artifact digest"
    return True, "rfc3161 token verified against trust roots and the exact checkpoint text"


def verify_git(cp, cpdir, expect_repo, branch):
    repo = os.path.join(cpdir, cp["artifact"]["repo_dir"])
    if not os.path.isdir(os.path.join(repo, ".git")) and not os.path.isdir(repo): raise Blocked("checkpoint repository not available: %s" % repo)
    commit, path = cp["artifact"]["commit"], cp["artifact"]["manifest_path"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit or ""): return False, "malformed commit reference"
    if _run(["git", "-C", repo, "cat-file", "-e", commit + "^{commit}"]).returncode != 0: return False, "commit does not exist in the retained repository"
    if expect_repo:
        url = _run(["git", "-C", repo, "config", "--get", "remote.origin.url"]).stdout.strip()
        norm = lambda u: re.sub(r"(\.git)?/?$", "", re.sub(r"^(https://|git@|ssh://git@)", "", u)).replace(":", "/")
        have, want = norm(url), norm(expect_repo)
        # `want` may be 'host/owner/name' (exact) or 'owner/name' (must be the trailing path of the origin on a path boundary)
        if not (have == want or (want.count("/") == 1 and have.endswith("/" + want))): return False, "repository identity mismatch (%s != %s)" % (url, expect_repo)
    if branch and _run(["git", "-C", repo, "merge-base", "--is-ancestor", commit, branch]).returncode != 0: return False, "commit is not an ancestor of %s" % branch
    blob = _run(["git", "-C", repo, "show", "%s:%s" % (commit, path)])
    if blob.returncode != 0: return False, "manifest path absent at that commit"
    if hashlib.sha256(blob.stdout.encode()).hexdigest() != cp["checkpoint_sha256"]: return False, "manifest content does not cover this exact checkpoint"
    return True, "git commit exists, repository identity matches, manifest covers the exact checkpoint"


# ------------------------------------------------------------------------------------------------ main verification
def verify_org(org, pages, checkpoints, cpdir, db_anchors, opt):
    rep = dict(organization_id=org, status=None, checks=[], checkpoints=[])
    now = opt["now"]
    events, ch = verify_chain(org, pages)
    rep["chain"] = ch
    if not ch["valid"]:
        rep["status"] = "chain_mismatch"; return rep
    if not ch.get("export_complete"):
        rep["status"] = "blocked_incomplete_export"; return rep
    n = len(events)
    verified, fixtures = [], False
    for cp in sorted(checkpoints, key=lambda c: int(c["event_count"])):
        c = dict(event_count=int(cp["event_count"]), evidence_type=cp["evidence_type"], class_=cp.get("class"), result=None, detail=None)
        cnt = c["event_count"]
        if cnt > n:
            c.update(result="truncated_history", detail="retained checkpoint at %d but the database holds %d events" % (cnt, n))
        else:
            ev = events[cnt - 1]
            got = (ev["id"], ev["event_hash"], ev["created_at"])
            if got != (cp["head_event_id"], cp["head_hash"], cp["head_at_iso"]):
                c.update(result="anchor_mismatch", detail="event %d differs from the retained checkpoint (id/hash/timestamp)" % cnt)
            elif checkpoint_digest(org, cnt, cp["head_event_id"], cp["head_hash"], cp["head_at_iso"]) != cp["checkpoint_sha256"]:
                c.update(result="artifact_invalid", detail="checkpoint digest does not match the checkpoint fields")
            else:
                try:
                    ok, why = (verify_rfc3161(cp, cpdir, opt.get("tsa_roots")) if cp["evidence_type"] == "rfc3161" else verify_git(cp, cpdir, opt.get("git_repository"), opt.get("git_branch")))
                    c.update(result="authentic" if ok else "artifact_invalid", detail=why)
                except Blocked as b:
                    c.update(result="blocked", detail=str(b))
        if c["result"] == "authentic":
            verified.append(c)
            if cp.get("class") == "TEST_FIXTURE": fixtures = True
        rep["checkpoints"].append(c)

    # database anchor list vs externally retained checkpoints
    keyf = lambda o, c, h, t: (o, int(c), h, t)
    retained = {keyf(org, c["event_count"], c["head_hash"], c["evidence_type"]) for c in checkpoints}
    dbset = {keyf(a["organization_id"], a["event_count"], a["head_hash"], a["evidence_type"]) for a in db_anchors}
    rep["anchors_missing_in_database"] = sorted([list(x[1:]) for x in retained - dbset])
    rep["anchors_not_retained_externally"] = sorted([list(x[1:]) for x in dbset - retained])

    results = {c["result"] for c in rep["checkpoints"]}
    if "truncated_history" in results: rep["status"] = "truncated_history"
    elif "anchor_mismatch" in results: rep["status"] = "anchor_mismatch"
    elif "artifact_invalid" in results: rep["status"] = "artifact_invalid"
    elif "blocked" in results: rep["status"] = "blocked"
    elif rep["anchors_missing_in_database"]: rep["status"] = "missing_anchor"
    elif rep["anchors_not_retained_externally"]: rep["status"] = "anchor_not_retained_externally"
    elif not verified: rep["status"] = "valid_unanchored"
    else:
        last = verified[-1]["event_count"]
        tail = n - last
        rep["unanchored_tail_events"] = tail
        if tail > 0:
            oldest = dt.datetime.fromisoformat(events[last]["created_at"])
            age = (now - oldest).total_seconds(); rep["oldest_unanchored_age_seconds"] = age
            if age > opt["max_unanchored_age"]: rep["status"] = "stale_anchor"
        if rep["status"] is None:
            rep["status"] = "verified_test_fixture" if (fixtures and not opt.get("allow_test_fixtures")) else "verified"
    rep["head"] = dict(event_count=n, head_hash=events[-1]["event_hash"] if events else None)
    return rep


INTEGRITY = {"chain_mismatch", "truncated_history", "anchor_mismatch", "artifact_invalid"}
BLOCKED = {"blocked", "blocked_incomplete_export"}


def run(args):
    now = dt.datetime.fromisoformat(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
    orgs = {}
    for fn in sorted(os.listdir(args.export_dir)):
        m = re.fullmatch(r"([0-9a-f-]{36})\.page-(\d+)\.json", fn)
        if m: orgs.setdefault(m.group(1), []).append((int(m.group(2)), load_json(open(os.path.join(args.export_dir, fn)).read())))
    report = dict(verifier="aios-audit-verify/1", algorithm_version=ALGO, verified_at=now.isoformat(), organizations=[], overall=None, certification_grade=False,
                  note="TEST_FIXTURE artifacts and test trust roots never constitute production evidence")
    for org, pg in sorted(orgs.items()):
        pages = [p for _, p in sorted(pg, key=lambda x: x[0])]
        cpdir = os.path.join(args.checkpoints, org)
        cps = [load_json(open(os.path.join(cpdir, f)).read()) for f in sorted(os.listdir(cpdir)) if f.endswith(".checkpoint.json")] if os.path.isdir(cpdir) else []
        dbp = os.path.join(args.export_dir, org + ".anchors.json")
        dba = load_json(open(dbp).read()) if os.path.exists(dbp) else []
        report["organizations"].append(verify_org(org, pages, cps, cpdir, dba, dict(now=now, max_unanchored_age=args.max_unanchored_age_seconds, tsa_roots=args.tsa_roots,
                                                                                    git_repository=args.git_repository, git_branch=args.git_branch, allow_test_fixtures=args.allow_test_fixtures)))
    st = {o["status"] for o in report["organizations"]}
    report["overall"] = "FAIL" if st & INTEGRITY or "chain_mismatch" in st else ("BLOCKED" if st & BLOCKED else ("VERIFIED" if st == {"verified"} and st else "INCOMPLETE"))
    if not report["organizations"]: report["overall"] = "BLOCKED"; report["note"] += "; no organizations exported"
    text = json.dumps(report, indent=2, sort_keys=True, default=str)
    if args.report: open(args.report, "w").write(text + "\n")
    report["_sha256"] = hashlib.sha256(text.encode()).hexdigest()
    return report


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--export-dir", required=True, help="dir of <org>.page-N.json (RPC aios_audit_chain_export) and <org>.anchors.json (RPC aios_audit_anchors_list)")
    ap.add_argument("--checkpoints", required=True, help="externally retained checkpoints: <dir>/<org>/*.checkpoint.json (+ artifacts)")
    ap.add_argument("--tsa-roots"); ap.add_argument("--git-repository"); ap.add_argument("--git-branch")
    ap.add_argument("--max-unanchored-age-seconds", type=float, default=7200)
    ap.add_argument("--allow-test-fixtures", action="store_true"); ap.add_argument("--now"); ap.add_argument("--report")
    a = ap.parse_args(argv)
    r = run(a)
    print(json.dumps({"overall": r["overall"], "organizations": [{"organization_id": o["organization_id"], "status": o["status"]} for o in r["organizations"]]}))
    st = {o["status"] for o in r["organizations"]}
    return 2 if (st & INTEGRITY) else 3 if r["overall"] == "BLOCKED" else 0 if r["overall"] == "VERIFIED" else 2


if __name__ == "__main__":
    sys.exit(main())
