"""rpc_tools against a local fake PostgREST: pagination, bounded pages, no secret echo, and 'an outage is never posted as success'."""
import io, json, os, sys, tempfile, threading, unittest, contextlib
from http.server import BaseHTTPRequestHandler, HTTPServer
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools", "audit-verify"))
import rpc_tools as rt  # noqa: E402

ORG = "aaaaaaaa-0000-4000-8000-000000000001"; KEY = "super-secret-service-key-xyz"
CALLS = []


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])) or b"{}"); fn = self.path.rsplit("/", 1)[1]
        CALLS.append((fn, body, self.headers.get("authorization")))
        if self.headers.get("authorization") != "Bearer " + KEY: self.send_response(401); self.end_headers(); self.wfile.write(b'{"leak":"%s"}' % KEY.encode()); return
        if fn == "aios_audit_heads": out = [{"organization_id": ORG}]
        elif fn == "aios_audit_chain_export":
            a, l = body["p_after_count"], body["p_limit"]; assert 1 <= l <= 1000
            evs = [{"seq": i} for i in range(a + 1, min(a + l, 2500) + 1)]
            out = {"returned": len(evs), "has_more": a + len(evs) < 2500, "events": evs, "total_events": 2500}
        elif fn == "aios_audit_anchors_list": out = [{"id": 7, "event_count": 2000, "evidence_type": "git", "head_hash": "a" * 64}]
        else: out = {"ok": True}
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(json.dumps(out).encode())


class T(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = HTTPServer(("127.0.0.1", 0), H); cls.url = "http://127.0.0.1:%d" % cls.srv.server_port
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls): cls.srv.shutdown()

    def setUp(self): CALLS.clear(); self.d = tempfile.mkdtemp()

    def test_fetch_paginates_and_is_bounded(self):
        self.assertEqual(rt.fetch(self.url, KEY, self.d), 0)
        pages = sorted(f for f in os.listdir(self.d) if ".page-" in f)
        self.assertEqual(len(pages), 3)                                     # 2500 events / 1000 per page
        self.assertTrue(all(c[1]["p_limit"] == 1000 for c in CALLS if c[0] == "aios_audit_chain_export"))
        self.assertEqual([c[1]["p_after_count"] for c in CALLS if c[0] == "aios_audit_chain_export"], [0, 1000, 2000])

    def test_wrong_key_fails_without_echoing_the_response_body(self):
        with self.assertRaises(SystemExit) as e: rt.fetch(self.url, "wrong", self.d)
        self.assertNotIn(KEY, str(e.exception))

    def test_unreachable_is_blocked_not_success(self):
        with self.assertRaises(SystemExit) as e: rt.rpc("http://127.0.0.1:1", KEY, "aios_audit_heads", {}, timeout=2)
        self.assertIn("BLOCKED", str(e.exception))

    def _report(self, overall, status):
        os.environ["AIOS_ANCHORS_DIR"] = self.d
        json.dump([{"id": 7, "event_count": 2000, "evidence_type": "git", "head_hash": "a" * 64}], open(os.path.join(self.d, ORG + ".anchors.json"), "w"))
        p = os.path.join(self.d, "report.json")
        json.dump({"overall": overall, "verifier": "t", "organizations": [{"organization_id": ORG, "status": status, "checkpoints": [{"event_count": 2000, "evidence_type": "git", "result": "authentic"}]}]}, open(p, "w"))
        return p

    def test_blocked_posts_nothing(self):
        rt.post(self.url, KEY, self._report("BLOCKED", "blocked")); self.assertEqual(CALLS, [])

    def test_incomplete_posts_nothing(self):
        rt.post(self.url, KEY, self._report("INCOMPLETE", "valid_unanchored")); self.assertEqual(CALLS, [])

    def test_verified_posts_ok_true_bound_to_the_anchor(self):
        rt.post(self.url, KEY, self._report("VERIFIED", "verified"))
        (fn, body, _), = CALLS
        self.assertEqual(fn, "aios_audit_record_external_verification"); self.assertTrue(body["p_ok"]); self.assertEqual((body["p_anchor_id"], body["p_event_count"]), (7, 2000))
        self.assertRegex(body["p_report_sha256"], r"^[0-9a-f]{64}$")

    def test_integrity_failure_posts_ok_false(self):
        rt.post(self.url, KEY, self._report("FAIL", "anchor_mismatch")); self.assertFalse(CALLS[0][1]["p_ok"])


if __name__ == "__main__":
    unittest.main()
