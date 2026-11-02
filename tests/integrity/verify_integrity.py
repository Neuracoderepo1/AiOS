#!/usr/bin/env python3
"""Verify certification evidence + canonical matrix manifest against an independently pinned hash set.

Usage: verify_integrity.py --root <repo> --pins <pin file> [--expect-pins-sha256 <hex>]

Fails (exit 1) on: manifest modified, evidence file modified/deleted/added/renamed, malformed or
mismatching pin file. Expected hashes come ONLY from the pin file (and, optionally, the pin file's own
hash supplied from an independent location such as the CI workflow) - never from files under test.
Pure stdlib, deterministic, no dependence on git state or developer-local files.
"""
import argparse, hashlib, os, re, sys

EVIDENCE = "docs/testing/evidence"
MANIFEST = "tests/matrix/manifest.json"
LINE = re.compile(r"^([0-9a-f]{64})  (\S.*)$")

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()

def load_pins(path):
    pins, errs = {}, []
    for n, raw in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        if not raw or raw.startswith("#"):
            continue
        m = LINE.match(raw)
        if not m:
            errs.append("pin file line %d malformed" % n); continue
        if m.group(2) in pins:
            errs.append("duplicate pin for " + m.group(2))
        pins[m.group(2)] = m.group(1)
    if not pins: errs.append("pin file has no entries")
    if MANIFEST not in pins: errs.append("pin file does not pin " + MANIFEST)
    return pins, errs

def actual_files(root):
    out = set()
    base = os.path.join(root, EVIDENCE)
    for d, _, fs in os.walk(base):
        for f in fs:
            out.add(os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/"))
    out.add(MANIFEST)
    return out

def verify(root, pins_path, expect_pins_sha=None):
    errs = []
    if not os.path.isfile(pins_path):
        return ["pin file missing: " + pins_path]
    if expect_pins_sha and sha(pins_path) != expect_pins_sha:
        errs.append("pin file hash does not match independently supplied expected hash")
    pins, e = load_pins(pins_path); errs += e
    have = actual_files(root)
    for p in sorted(set(pins) - have): errs.append("MISSING (deleted or renamed away): " + p)
    for p in sorted(have - set(pins)): errs.append("UNEXPECTED (added or renamed to): " + p)
    for p in sorted(set(pins) & have):
        if sha(os.path.join(root, p)) != pins[p]: errs.append("MODIFIED: " + p)
    return errs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--pins", required=True)
    ap.add_argument("--expect-pins-sha256", default=None)
    a = ap.parse_args()
    errs = verify(a.root, a.pins, a.expect_pins_sha256)
    if errs:
        print("INTEGRITY FAIL"); [print("  - " + e) for e in errs]; sys.exit(1)
    print("INTEGRITY PASS (%s)" % a.pins)

if __name__ == "__main__":
    main()
