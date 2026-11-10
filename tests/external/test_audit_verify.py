"""Independent external verifier tests (Part E, E06). Needs the e2e fixture directory (tests/external/e2e.sh sets AIOS_E2E_DIR).
A missing prerequisite is an ERROR (blocked), never a skip or a pass."""
import argparse, copy, json, os, shutil, subprocess, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools", "audit-verify"))
import audit_verify as av  # noqa: E402

ORG = "e2e00000-0000-4000-8000-0000000000e1"
NOW = "2026-03-01T00:30:00+00:00"          # 12 events span 00:01..00:12 on 2026-03-01 (event 4 has +123456 us)


def ns(export_dir, ckpt, **kw):
    d = dict(export_dir=export_dir, checkpoints=ckpt, tsa_roots=None, git_repository="example/aios-audit-checkpoints", git_branch="main",
             max_unanchored_age_seconds=7200, allow_test_fixtures=True, now=NOW, report=None)
    d.update(kw)
    return argparse.Namespace(**d)


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.D = os.environ.get("AIOS_E2E_DIR")
        if not cls.D or not os.path.exists(os.path.join(cls.D, "export", ORG + ".anchors.json")):
            raise RuntimeError("BLOCKED: e2e fixture missing - run tests/external/e2e.sh (phases 1-3 need a database, openssl and git)")
        cls.roots = os.path.join(cls.D, "tsa-roots.pem"); cls.other = os.path.join(cls.D, "tsa-roots-other.pem")

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.exp = os.path.join(self.tmp, "export"); self.ck = os.path.join(self.tmp, "checkpoints")
        shutil.copytree(os.path.join(self.D, "export"), self.exp); shutil.copytree(os.path.join(self.D, "checkpoints"), self.ck, symlinks=True)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # helpers
    def pages(self):
        return [av.load_json(open(os.path.join(self.exp, "%s.page-%d.json" % (ORG, i))).read()) for i in (1, 2, 3)]

    def save(self, pages):
        for i, p in enumerate(pages, 1):
            open(os.path.join(self.exp, "%s.page-%d.json" % (ORG, i)), "w").write(av.jsonb_text(p))

    def verify(self, **kw):
        kw.setdefault("tsa_roots", self.roots)
        return av.run(ns(self.exp, self.ck, **kw))

    def status(self, **kw):
        return self.verify(**kw)["organizations"][0]["status"]

    def events(self, pages):
        return [e for p in pages for e in p["events"]]


class TestHappyPath(Base):
    def test_verified_with_real_artifacts(self):
        r = self.verify()
        o = r["organizations"][0]
        self.assertEqual(o["status"], "verified", json.dumps(o, indent=1, default=str)[:900])
        self.assertEqual([c["result"] for c in o["checkpoints"]], ["authentic", "authentic"])
        self.assertEqual(o["unanchored_tail_events"], 3)
        self.assertFalse(r["certification_grade"])

    def test_test_fixture_is_never_production_verified(self):
        self.assertEqual(self.status(allow_test_fixtures=False), "verified_test_fixture")
        self.assertEqual(self.verify(allow_test_fixtures=False)["overall"], "INCOMPLETE")

    def test_cli_exit_codes(self):
        base = [sys.executable, os.path.join(os.path.dirname(av.__file__), "audit_verify.py"), "--export-dir", self.exp, "--checkpoints", self.ck, "--now", NOW,
                "--git-repository", "example/aios-audit-checkpoints", "--git-branch", "main", "--allow-test-fixtures"]
        ok = subprocess.run(base + ["--tsa-roots", self.roots], capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        blocked = subprocess.run(base, capture_output=True, text=True)               # no trust roots
        self.assertEqual(blocked.returncode, 3, "missing trust roots must be BLOCKED (3), never success")
        bad = subprocess.run(base + ["--tsa-roots", self.other], capture_output=True, text=True)
        self.assertEqual(bad.returncode, 2)


class TestGolden(unittest.TestCase):
    def test_golden_vectors_from_real_trigger(self):
        g = av.load_json(open(os.path.join(os.path.dirname(__file__), "..", "golden", "audit-golden-vectors.json")).read())
        self.assertGreaterEqual(len(g["vectors"]), 5)
        for v in g["vectors"]:
            ev = v["event"]; prev = ev["previous_event_hash"]
            self.assertEqual(av.canonical_payload(ev, prev), v["expected_payload"], "payload differs for seq %s" % v["seq"])
            self.assertEqual(av.canonical_hash(ev, prev), v["expected_event_hash"])

    def test_double_inclusion_of_previous_hash(self):
        ev = {k: None for k in av.KEYS}; ev.update(id="x", metadata={}, created_at="2026-01-01T00:00:00+00:00")
        p = av.canonical_payload(ev, "PREV")
        self.assertTrue(p.endswith('"previous_event_hash": "PREV"}PREV'))

    def test_jsonb_key_order_is_length_then_bytes(self):
        self.assertEqual(av.jsonb_text({"bb": 1, "a": 2, "ab": 3, "é": 4}), '{"a": 2, "ab": 3, "bb": 1, "é": 4}')   # order confirmed against PostgreSQL 16 jsonb::text


class TestChainTamper(Base):
    def test_altered_metadata(self):
        p = self.pages(); p[0]["events"][1]["metadata"] = {"tampered": av.Num("1")}; self.save(p)
        self.assertEqual(self.status(), "chain_mismatch")

    def test_altered_event_hash(self):
        p = self.pages(); p[1]["events"][2]["event_hash"] = "0" * 64; self.save(p)
        self.assertEqual(self.status(), "chain_mismatch")

    def test_altered_previous_hash(self):
        p = self.pages(); p[1]["events"][0]["previous_event_hash"] = "1" * 64; self.save(p)
        self.assertEqual(self.status(), "chain_mismatch")

    def test_deleted_middle_event(self):
        p = self.pages(); del p[0]["events"][2]; self.save(p)
        self.assertEqual(self.status(), "chain_mismatch")

    def test_altered_timestamp(self):
        p = self.pages(); p[0]["events"][3]["created_at"] = "2026-03-01T00:04:00.123457+00:00"; self.save(p)
        self.assertEqual(self.status(), "chain_mismatch")

    def test_truncated_tail_before_anchor_is_caught_by_the_anchor(self):
        p = self.pages()
        p[2]["events"] = p[2]["events"][:0]            # drop events 11-12 ...
        p[1]["events"] = p[1]["events"][:2]            # ... and 8-10 => history ends at 7 (< checkpoint at 9)
        for x in p: x["total_events"] = 7; x["head_hash"] = p[1]["events"][-1]["event_hash"]
        self.save(p)
        self.assertEqual(av.verify_chain(ORG, self.pages())[1]["valid"], True)          # the bare chain is still valid ...
        self.assertEqual(self.status(), "truncated_history")                              # ... only the external checkpoint reveals it

    def test_resealed_history_is_caught_by_the_anchor(self):
        p = self.pages(); evs = self.events(p)
        evs[1]["metadata"] = {"rewritten": av.Num("1")}
        prev = "GENESIS:" + ORG
        for e in evs:
            e["previous_event_hash"] = prev; e["event_hash"] = av.canonical_hash(e, prev); prev = e["event_hash"]
        for x in p: x["head_hash"] = prev
        self.save(p)
        self.assertTrue(av.verify_chain(ORG, self.pages())[1]["valid"])                   # a consistent rewrite is a valid chain
        self.assertEqual(self.status(), "anchor_mismatch")

    def test_missing_page_is_blocked_not_verified(self):
        os.remove(os.path.join(self.exp, "%s.page-3.json" % ORG))
        self.assertEqual(self.status(), "blocked_incomplete_export")
        self.assertEqual(self.verify()["overall"], "BLOCKED")


class TestArtifacts(Base):
    def test_tampered_tsa_token(self):
        f = os.path.join(self.ck, ORG, "9.tsr"); b = bytearray(open(f, "rb").read()); b[len(b) // 2] ^= 0xFF; open(f, "wb").write(bytes(b))
        self.assertEqual(self.status(), "artifact_invalid")

    def test_token_over_a_different_checkpoint(self):
        d = os.path.join(self.ck, ORG)
        shutil.copy(os.path.join(d, "9.tsr"), os.path.join(d, "9x.tsr")); other = open(os.path.join(d, "9.txt")).read().replace("e2e.event", "x") + "x"
        open(os.path.join(d, "9.txt"), "w").write(other)
        self.assertEqual(self.status(), "artifact_invalid")

    def test_untrusted_ca(self):
        self.assertEqual(self.status(tsa_roots=self.other), "artifact_invalid")

    def test_missing_trust_roots_is_blocked(self):
        r = self.verify(tsa_roots=None); self.assertEqual(r["organizations"][0]["status"], "blocked"); self.assertEqual(r["overall"], "BLOCKED")

    def test_missing_artifact_is_blocked(self):
        os.remove(os.path.join(self.ck, ORG, "9.tsr"))
        self.assertEqual(self.status(), "blocked")

    def test_fabricated_git_commit(self):
        f = os.path.join(self.ck, ORG, "6.checkpoint.json"); c = json.load(open(f)); c["artifact"]["commit"] = "d" * 40; json.dump(c, open(f, "w"))
        self.assertEqual(self.status(), "artifact_invalid")

    def test_git_repository_identity_mismatch(self):
        self.assertEqual(self.status(git_repository="attacker/other-repo"), "artifact_invalid")

    def test_git_manifest_does_not_cover_the_checkpoint(self):
        repo = os.path.join(self.ck, ORG, "repo"); env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e.t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@e.t")
        open(os.path.join(repo, "cp", ORG, "6.txt"), "w").write("a different manifest")
        subprocess.run(["git", "-C", repo, "commit", "-qam", "swap"], check=True, env=env)
        c = json.load(open(os.path.join(self.ck, ORG, "6.checkpoint.json")))
        c["artifact"]["commit"] = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        json.dump(c, open(os.path.join(self.ck, ORG, "6.checkpoint.json"), "w"))
        self.assertEqual(self.status(), "artifact_invalid")

    def test_git_commit_not_reachable_from_branch(self):
        self.assertEqual(self.status(git_branch="refs/heads/does-not-exist"), "artifact_invalid")


class TestCoverageAndFreshness(Base):
    def test_no_checkpoints_is_valid_unanchored(self):
        shutil.rmtree(os.path.join(self.ck, ORG)); os.remove(os.path.join(self.exp, ORG + ".anchors.json"))
        r = self.verify(); self.assertEqual(r["organizations"][0]["status"], "valid_unanchored"); self.assertNotEqual(r["overall"], "VERIFIED")

    def test_retained_checkpoint_missing_from_database(self):
        a = av.load_json(open(os.path.join(self.exp, ORG + ".anchors.json")).read())
        json.dump([x for x in a if int(x["event_count"]) != 9], open(os.path.join(self.exp, ORG + ".anchors.json"), "w"))
        self.assertEqual(self.status(), "missing_anchor")

    def test_database_anchor_without_external_artifact(self):
        os.remove(os.path.join(self.ck, ORG, "9.checkpoint.json"))
        self.assertEqual(self.status(), "anchor_not_retained_externally")

    def test_stale_anchor_boundary(self):
        # oldest unanchored event = event 10 at 2026-03-01T00:10:00Z; threshold 7200s
        fresh = "2026-03-01T02:09:55+00:00"; stale = "2026-03-01T02:10:05+00:00"
        self.assertEqual(self.status(now=fresh), "verified")
        self.assertEqual(self.status(now=stale), "stale_anchor")

    def test_snapshot_drift_is_reported_not_hidden(self):
        p = self.pages(); p[0]["total_events"] = 11; self.save(p)
        o = self.verify()["organizations"][0]
        self.assertTrue(o["chain"]["snapshot_drift"])


if __name__ == "__main__":
    unittest.main()


class TestBuildFromIndependentArtifacts(Base):
    """The workflow builds retained checkpoints from the git clone / token files themselves, never from the database."""
    def test_descriptors_rebuilt_from_git_and_tokens_verify(self):
        import build_checkpoints as bc
        out = os.path.join(self.tmp, "rebuilt"); tsr = os.path.join(self.tmp, "tsr", ORG); os.makedirs(tsr)
        for n in (9,):
            for ext in ("tsr", "txt"): shutil.copy(os.path.join(self.ck, ORG, "%d.%s" % (n, ext)), tsr)
        self.assertEqual(bc.main(["--git-repo", os.path.join(self.ck, ORG, "repo"), "--tsr-dir", os.path.join(self.tmp, "tsr"), "--out", out]), 0)
        r = av.run(ns(self.exp, out, tsa_roots=self.roots))
        self.assertEqual(r["organizations"][0]["status"], "verified", json.dumps(r["organizations"][0], default=str)[:600])

    def test_nothing_retained_is_blocked(self):
        import build_checkpoints as bc
        self.assertEqual(bc.main(["--out", os.path.join(self.tmp, "x")]), 3)
