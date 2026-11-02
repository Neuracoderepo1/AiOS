#!/usr/bin/env python3
"""Reconstruct canonical-matrix evidence from a raw GitHub Actions JOB LOG.

Never edits or invents records. It (1) hashes the untouched raw log, (2) slices out the tests/matrix/run.sh section with
timestamps stripped, (3) copies every MX_RESULT line and the G4 section verbatim, (4) re-runs the repository's own
verify.py (from the named commit) over those slices, and (5) compares the reproduced verifier output with the verifier
output that CI itself printed into the same log. Any disagreement exits non-zero.

Usage: reconstruct_matrix_evidence.py --raw JOB.log --verify verify.py --manifest manifest.json --out DIR
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--raw", required=True)
ap.add_argument("--verify", required=True)
ap.add_argument("--manifest", required=True)
ap.add_argument("--out", required=True)
a = ap.parse_args()

TS = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
raw_bytes = open(a.raw, "rb").read()
if not raw_bytes:
    sys.exit("raw log is zero bytes; refusing to continue")
raw = raw_bytes.decode("utf-8", errors="replace").replace("\r\n", "\n")
body = [TS.sub("", l, count=1) for l in raw.split("\n")]

def find(pred, start=0):
    for i in range(start, len(body)):
        if pred(body[i]):
            return i
    return None

i0 = find(lambda s: s.startswith("##[group]Run") and "tests/matrix/run.sh" in s)
if i0 is None:
    # the group header echoes only the first script line; fall back to the script echo itself
    i0 = find(lambda s: "bash tests/matrix/run.sh" in s)
if i0 is None:
    sys.exit("could not locate the tests/matrix/run.sh step in the job log")
iv = find(lambda s: s.startswith("== verify against manifest"), i0)
if iv is None:
    sys.exit("matrix step is incomplete in this log: no '== verify against manifest' marker")
ie = find(lambda s: s.startswith("##[group]") or s.startswith("##[error]"), iv + 1)
ie = len(body) if ie is None else ie
sec = body[i0:ie]
i_sql = find(lambda s: s.startswith("== 05_certification_matrix"), i0)
i_g4 = find(lambda s: s.startswith("== G4 eight-way concurrency"), i0)
if None in (i_sql, i_g4) or not (i_sql < i_g4 < iv):
    sys.exit("section markers missing or out of order")

sql_part = body[i_sql + 1:i_g4]
g4_part = body[i_g4 + 1:iv]
ci_verify = [l for l in body[iv + 1:ie] if l.strip() != "" and not l.startswith("##[")]

out = a.out
for d in ("raw", "extracted"):
    os.makedirs(os.path.join(out, d), exist_ok=True)
raw_name = os.path.basename(a.raw)
shutil.copyfile(a.raw, os.path.join(out, "raw", raw_name))  # byte-exact original

def w(name, lines):
    p = os.path.join(out, "extracted", name)
    open(p, "w").write("\n".join(lines) + "\n")
    return p

w("matrix-run.txt", [l for l in sec if not l.startswith("##[")])
mx = [l for l in sql_part if l.startswith("MX_RESULT|")]
w("mx_results.txt", mx)
w("sql-05.reconstructed.log", sql_part)   # verbatim slice (only MX_RESULT/ok/ERROR lines survive in CI output)
w("g4.log", g4_part)
w("ci-verifier-output.txt", ci_verify)

r = subprocess.run([sys.executable, a.verify, "--manifest", a.manifest,
                    "--sql-log", os.path.join(out, "extracted", "sql-05.reconstructed.log"),
                    "--g4-log", os.path.join(out, "extracted", "g4.log"),
                    "--report", os.path.join(out, "extracted", "report.reproduced.json")],
                   capture_output=True, text=True)
repro = r.stdout.rstrip("\n").split("\n")
w("verify-reproduced.txt", repro)

man = json.load(open(a.manifest))
rep = json.load(open(os.path.join(out, "extracted", "report.reproduced.json")))
ids = [l.split("|", 2)[1] for l in mx]
truncated = sum(1 for l in mx if len(l) >= 240)
agree = [l.strip() for l in repro if l.strip()] == [l.strip() for l in ci_verify if l.strip()]

summary = {
    "raw_log": raw_name, "raw_bytes": len(raw_bytes), "raw_sha256": hashlib.sha256(raw_bytes).hexdigest(),
    "mx_result_records": len(mx), "unique_case_ids": len(set(ids)), "has_G4_checks": rep["g4_checks"],
    "manifest_total": man["total_cases"], "passed": rep["passed"], "per_domain": rep["per_domain"],
    "mx_records_at_240_char_cut": truncated, "verifier_exit_code": r.returncode,
    "reproduced_equals_ci_verifier_output": agree, "errors": rep["errors"], "ok": rep["ok"] and agree,
}
json.dump(summary, open(os.path.join(out, "extracted", "summary.json"), "w"), indent=2)

sums = []
for root, _, files in os.walk(out):
    for f in sorted(files):
        if f == "SHA256SUMS":
            continue
        p = os.path.join(root, f)
        sums.append(f"{hashlib.sha256(open(p,'rb').read()).hexdigest()}  {os.path.relpath(p, out)}")
open(os.path.join(out, "SHA256SUMS"), "w").write("\n".join(sorted(sums, key=lambda x: x.split('  ')[1])) + "\n")

print(json.dumps(summary, indent=2))
sys.exit(0 if summary["ok"] else 1)
