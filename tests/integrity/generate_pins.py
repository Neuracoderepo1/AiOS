#!/usr/bin/env python3
"""Generate an integrity pin file from git BLOBS of an approved commit (never from the working tree).

Usage: generate_pins.py --commit <sha> --out tests/integrity/pins/<version>.pins [--baseline-commit <sha>]
The output is deterministic: sorted paths, LF endings, no timestamps. Commit it only via the
authorized procedure in docs/testing/INTEGRITY.md. Existing pin files are never overwritten.
"""
import argparse, hashlib, subprocess, sys, os

EVIDENCE = "docs/testing/evidence/"
MANIFEST = "tests/matrix/manifest.json"

def git(*a):
    return subprocess.check_output(["git", *a])

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--commit", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--baseline-commit", default="")
    a = p.parse_args()
    if os.path.exists(a.out):
        sys.exit("refusing to overwrite existing pin file: " + a.out)
    sha = git("rev-parse", "--verify", a.commit + "^{commit}").decode().strip()
    paths = git("ls-tree", "-r", "--name-only", sha, "--", EVIDENCE.rstrip("/")).decode().split("\n")
    paths = sorted(x for x in paths if x) + [MANIFEST]
    lines = ["# AiOS integrity pins. Generated from git blobs of commit %s" % sha]
    if a.baseline_commit:
        lines.append("# baseline_commit=%s" % a.baseline_commit)
    lines.append("# format: <sha256>  <path>   (paths under %s plus %s; the set must match exactly)" % (EVIDENCE, MANIFEST))
    for path in paths:
        blob = git("show", "%s:%s" % (sha, path))
        lines.append("%s  %s" % (hashlib.sha256(blob).hexdigest(), path))
    open(a.out, "w", newline="\n").write("\n".join(lines) + "\n")
    print("wrote %s (%d entries)" % (a.out, len(paths)))

if __name__ == "__main__":
    main()
