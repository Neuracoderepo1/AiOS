#!/usr/bin/env python3
"""Mutation tests for verify_integrity.py. Each case copies the pinned files to a temp dir, applies one
mutation, and asserts the expected outcome. Unauthorized mutations MUST fail; unchanged evidence MUST pass."""
import os, shutil, sys, tempfile, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import verify_integrity as v

PINS = os.path.join(HERE, "pins", "matrix-v1.pins")
EV = v.EVIDENCE

class Mut(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        shutil.copytree(os.path.join(ROOT, EV), os.path.join(self.t, EV))
        os.makedirs(os.path.join(self.t, "tests/matrix"))
        shutil.copy(os.path.join(ROOT, v.MANIFEST), os.path.join(self.t, v.MANIFEST))
    def tearDown(self): shutil.rmtree(self.t, ignore_errors=True)
    def p(self, rel): return os.path.join(self.t, rel)
    def run_v(self, pins=PINS, expect=None): return v.verify(self.t, pins, expect)

    def test_7_unchanged_passes(self): self.assertEqual(self.run_v(), [])
    def test_1_modified_manifest_fails(self):
        open(self.p(v.MANIFEST), "a").write("\n"); self.assertTrue(any("MODIFIED: " + v.MANIFEST in e for e in self.run_v()))
    def test_2_modified_evidence_fails(self):
        open(self.p(EV + "/README.md"), "a").write("x"); self.assertTrue(any("MODIFIED" in e for e in self.run_v()))
    def test_3_deleted_evidence_fails(self):
        os.remove(self.p(EV + "/extracted/g4.log")); self.assertTrue(any("MISSING" in e for e in self.run_v()))
    def test_4_additional_file_fails(self):
        open(self.p(EV + "/extra.txt"), "w").write("x"); self.assertTrue(any("UNEXPECTED" in e for e in self.run_v()))
    def test_5_renamed_evidence_fails(self):
        os.rename(self.p(EV + "/extracted/g4.log"), self.p(EV + "/extracted/g4-renamed.log"))
        errs = self.run_v(); self.assertTrue(any("MISSING" in e for e in errs) and any("UNEXPECTED" in e for e in errs))
    def test_6_incorrect_pinned_hash_fails(self):
        bad = self.p("bad.pins"); lines = open(PINS).read().split("\n")
        i = next(k for k, l in enumerate(lines) if l and not l.startswith("#"))
        lines[i] = ("0" * 64) + lines[i][64:]; open(bad, "w").write("\n".join(lines))
        self.assertTrue(any("MODIFIED" in e for e in self.run_v(bad)))
    def test_extra_pin_file_hash_mismatch_fails(self):
        self.assertTrue(any("independently supplied" in e for e in self.run_v(expect="0" * 64)))

if __name__ == "__main__":
    unittest.main(verbosity=2)
