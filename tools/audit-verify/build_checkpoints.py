#!/usr/bin/env python3
"""Builds the verifier's retained-checkpoint view from INDEPENDENT sources only (never from the database):
  * Git:     a clone of the checkpoint repository containing cp/<org>/<event_count>.txt  (the commit is taken from `git log`, not from any database field)
  * RFC3161: a directory tsr/<org>/<event_count>.tsr + <event_count>.txt                  (token and the exact checkpoint text)
Output: <out>/<org>/<n>.checkpoint.json (+ a 'repo' symlink for git), consumed by audit_verify.py. Never writes to any database."""
import argparse, hashlib, json, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from audit_verify import head_at_z  # noqa: E402  (only used to render checkpoints identically)

UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"


def parse_manifest(text, org, n):
    lines = text.split("\n")
    if len(lines) != 6 or lines[0] != "aios-audit-checkpoint-v1" or lines[1] != org or lines[2] != str(n) or not re.fullmatch(UUID, lines[3]) or not re.fullmatch(r"[0-9a-f]{64}", lines[4]) \
            or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z", lines[5]):
        raise ValueError("malformed checkpoint manifest for %s #%s" % (org, n))
    # export timestamps are jsonb text: '+00:00' with trimmed fraction; convert back for comparison with exported events
    ts = lines[5][:-1]; base, frac = ts.split("."); frac = frac.rstrip("0")
    return dict(head_event_id=lines[3], head_hash=lines[4], head_at_iso=base + ("." + frac if frac else "") + "+00:00")


def main(argv=None):
    ap = argparse.ArgumentParser(); ap.add_argument("--git-repo"); ap.add_argument("--tsr-dir"); ap.add_argument("--out", required=True); a = ap.parse_args(argv)
    made = 0
    if a.git_repo:
        base = os.path.join(a.git_repo, "cp")
        for org in sorted(os.listdir(base)) if os.path.isdir(base) else []:
            for f in sorted(os.listdir(os.path.join(base, org))):
                m = re.fullmatch(r"(\d+)\.txt", f)
                if not m: continue
                n = int(m.group(1)); path = "cp/%s/%s" % (org, f); text = open(os.path.join(base, org, f), newline="").read()
                commit = subprocess.run(["git", "-C", a.git_repo, "log", "-1", "--format=%H", "--", path], capture_output=True, text=True).stdout.strip()
                if not commit: raise SystemExit("manifest %s is not committed" % path)
                d = os.path.join(a.out, org); os.makedirs(d, exist_ok=True)
                link = os.path.join(d, "repo")
                if not os.path.lexists(link): os.symlink(os.path.abspath(a.git_repo), link)
                dig = hashlib.sha256(text.encode()).hexdigest()
                cp = dict(version="aios-audit-checkpoint-v1", organization_id=org, event_count=n, checkpoint_sha256=dig, evidence_type="git", artifact_sha256=dig,
                          artifact=dict(repo_dir="repo", commit=commit, manifest_path=path), **parse_manifest(text, org, n))
                json.dump(cp, open(os.path.join(d, "%d.checkpoint.json" % n), "w"), indent=2); made += 1
    if a.tsr_dir:
        for org in sorted(os.listdir(a.tsr_dir)):
            for f in sorted(os.listdir(os.path.join(a.tsr_dir, org))):
                m = re.fullmatch(r"(\d+)\.tsr", f)
                if not m: continue
                n = int(m.group(1)); txt = os.path.join(a.tsr_dir, org, "%d.txt" % n); text = open(txt, newline="").read()
                d = os.path.join(a.out, org); os.makedirs(d, exist_ok=True)
                for fn in (f, "%d.txt" % n):
                    dst = os.path.join(d, fn)
                    if not os.path.lexists(dst): open(dst, "wb").write(open(os.path.join(a.tsr_dir, org, fn), "rb").read())
                cp = dict(version="aios-audit-checkpoint-v1", organization_id=org, event_count=n, checkpoint_sha256=hashlib.sha256(text.encode()).hexdigest(), evidence_type="rfc3161",
                          artifact_sha256=hashlib.sha256(open(os.path.join(a.tsr_dir, org, f), "rb").read()).hexdigest(), artifact=dict(tsr=f, checkpoint_text="%d.txt" % n), **parse_manifest(text, org, n))
                json.dump(cp, open(os.path.join(d, "%d.checkpoint.json" % n), "w"), indent=2); made += 1
    print("built %d checkpoint descriptors from independent artifacts" % made)
    return 0 if made else 3          # nothing retained => BLOCKED, never success


if __name__ == "__main__":
    sys.exit(main())
