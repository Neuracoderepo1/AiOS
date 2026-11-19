#!/usr/bin/env python3
"""Regression test for the Part D/E result collector and rollback-proof notice contract."""
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


def write(out, name, content):
    (out / name).write_text(content, encoding="utf-8")


def main():
    with tempfile.TemporaryDirectory(prefix="aios-collector-test-") as tmp:
        out = pathlib.Path(tmp)
        write(out, "sql12.log", "NOTICE:  MXRES|PASS|D04.8.rollback|rollback|restore savepoint was rolled back\nNOTICE:  ROLLBACK_PROOF|PASS|D04.8.rollback|fixture absent after rollback\n")
        write(out, "sql13.log", "NOTICE:  MXRES|PASS|E02.8.rollback|rollback|timezone fixture was rolled back\nNOTICE:  ROLLBACK_PROOF|PASS|E02.8.rollback|timezone fixture absent after rollback\n")
        write(out, "regression-sql.log", "PASS tests/sql/01_security_invariants.sql\n")
        write(out, "races-restoration.results", "PASS|restore-race|barrier observed\n")
        write(out, "races-audit.results", "PASS|audit-race|barrier observed\n")
        write(out, "e2e.log", "testHappyPath (tests.external.test_audit_verify) ... ok\n")
        write(out, "rpc.log", "testRpcTool (tests.external.test_rpc_tools) ... ok\n")
        write(out, "deno.log", "audit-anchor core ... ok\n")
        write(out, "static.log", "static checks S1-S6: PASS\n")
        write(out, "static-selftest.log", "DETECTED mutation fixture\n")
        write(out, "goldens.log", "goldens match\n")
        proc = subprocess.run(
            [sys.executable, str(ROOT / "tests/harness/collect_results.py"), str(out)],
            cwd=ROOT, capture_output=True, text=True
        )
        if proc.returncode != 0:
            raise SystemExit("collector self-test failed:\n" + proc.stdout + proc.stderr)
        totals = json.loads((out / "totals.json").read_text())
        rollback = json.loads((out / "rollback-proof-results.json").read_text())
        behavioral = json.loads((out / "behavioral-results.json").read_text())
        assert totals["rollback_proof"]["PASS"] == 2, totals
        assert totals["rollback_proof"]["FAIL"] == 0 and totals["rollback_proof"]["BLOCKED"] == 0, totals
        assert len(rollback["results"]) == 2, rollback
        assert behavioral["totals"]["PASS"] >= 5, behavioral
        assert behavioral["totals"]["FAIL"] == 0 and behavioral["totals"]["BLOCKED"] == 0, behavioral
        print("PASS: MXRES, ROLLBACK_PROOF, static-check and golden-vector notice parsing")


if __name__ == "__main__":
    main()
