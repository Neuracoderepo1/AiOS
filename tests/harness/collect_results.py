#!/usr/bin/env python3
"""Builds the machine-readable result files from the RAW LOGS only. Nothing is inferred or hand-written: a check is PASS only if its log line says PASS;
a suite whose log is missing/empty is BLOCKED."""
import json, os, re, subprocess, sys
OUT = sys.argv[1]
sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
ENV = os.environ.get("AIOS_ENV_DESC", "local harness: PostgreSQL 16 + pg_cron on Ubuntu 24.04 (NOT Supabase; pg_jsonschema stubbed; auth schema shimmed)")


def rd(n):
    p = os.path.join(OUT, n); return open(p, errors="replace").read() if os.path.exists(p) and os.path.getsize(p) else None


def entry(i, purpose, cmd, status, actual, log):
    return dict(test_id=i, purpose=purpose, environment=ENV, commit_sha=sha, command=cmd, expected="PASS", actual=actual, status=status, log=log)


def sql(logname, suite, cmd):
    t = rd(logname)
    if t is None: return [entry(suite, "suite did not run", cmd, "BLOCKED", "no log produced", logname)]
    rows = []
    for m in re.finditer(r"^(PASS|FAIL) (\S+)\s+(\S+)\s?(.*)$", t, re.M):
        rows.append(entry("%s:%s" % (suite, m.group(2)), m.group(4).strip() or m.group(3), cmd, m.group(1), m.group(1), logname) | dict(domain=m.group(3)))
    if not rows: rows.append(entry(suite, "suite produced no result lines", cmd, "BLOCKED", t[-300:], logname))
    return rows


def results_file(logname, suite, cmd):
    t = rd(logname)
    if t is None: return [entry(suite, "suite did not run", cmd, "BLOCKED", "no results file", logname)]
    rows = []
    for ln in t.splitlines():
        s, i, d = (ln.split("|", 2) + ["", ""])[:3]
        if s in ("PASS", "FAIL"): rows.append(entry("%s:%s" % (suite, i.split()[0]), i + (" " + d if d else ""), cmd, s, s, logname))
    return rows or [entry(suite, "no result lines", cmd, "BLOCKED", "", logname)]


def unittest(logname, suite, cmd):
    t = rd(logname)
    if t is None: return [entry(suite, "suite did not run", cmd, "BLOCKED", "no log", logname)]
    rows = []
    for m in re.finditer(r"^(test\w+) \(([\w.]+)\)(?:\n.*?)? \.\.\. (ok|FAIL|ERROR|skipped.*)$", t, re.M):
        st = {"ok": "PASS", "FAIL": "FAIL", "ERROR": "FAIL"}.get(m.group(3), "BLOCKED")
        rows.append(entry("%s:%s.%s" % (suite, m.group(2).split(".")[-1], m.group(1)), "unittest " + m.group(1), cmd, st, m.group(3), logname))
    return rows or [entry(suite, "no unittest lines parsed", cmd, "BLOCKED", t[-300:], logname)]


def deno(logname):
    t = rd(logname) or ""
    if "BLOCKED" in t[:40] or not t: return [entry("deno", "deno unavailable", "deno check && deno test", "BLOCKED", t[:120], logname)]
    rows = []
    for m in re.finditer(r"^(.+?) \.\.\. \x1b?\[?0?m?\x1b?\[?\d*;?\d*m?(ok|FAILED)", re.sub(r"\x1b\[[0-9;]*m", "", t), re.M):
        pass
    clean = re.sub(r"\x1b\[[0-9;]*m", "", t)
    for m in re.finditer(r"^(.+?) \.\.\. (ok|FAILED)", clean, re.M):
        rows.append(entry("deno:" + re.sub(r"\W+", "_", m.group(1))[:70], m.group(1), "deno check && deno test", "PASS" if m.group(2) == "ok" else "FAIL", m.group(2), logname))
    return rows or [entry("deno", "no deno result lines", "deno test", "BLOCKED", clean[-200:], logname)]


def lines(logname, suite, cmd, pat):
    t = rd(logname)
    if t is None: return [entry(suite, "did not run", cmd, "BLOCKED", "no log", logname)]
    return [entry("%s:%s" % (suite, re.sub(r"\W+", "_", m.group(2))[:60]), m.group(2), cmd, "PASS" if m.group(1) in ("PASS", "DETECTED") else "FAIL", m.group(1), logname) for m in re.finditer(pat, t, re.M)] or [entry(suite, "no lines", cmd, "BLOCKED", "", logname)]


S12 = sql("sql12.log", "partD", "psql -f tests/sql_superuser/12_part_d_restoration.sql")
S13 = sql("sql13.log", "partE", "psql -f tests/sql_superuser/13_part_e_audit_anchoring.sql")
REG = lines("regression-sql.log", "regression-sql", "psql -f tests/sql/NN.sql (existing AiOS suite)", r"^(PASS|FAIL) (\S+)")
RR = results_file("races-restoration.results", "races-restoration", "tests/concurrency/restoration_races.sh")
AR = results_file("races-audit.results", "races-audit", "tests/concurrency/audit_append_races.sh")
E2E = unittest("e2e.log", "external-verifier", "tests/external/e2e.sh (python -m unittest tests.external.test_audit_verify)")
RPC = unittest("rpc.log", "rpc-tools", "python3 -m unittest tests.external.test_rpc_tools")
DENO = deno("deno.log")
STAT = lines("static.log", "static", "tests/static/check_part_de.py", r"^(static checks S1-S6: )(PASS)$")
SST = lines("static-selftest.log", "static-mutation", "tests/static/selftest.sh", r"^(DETECTED|NOT DETECTED) (.+)$")
GOLD = lines("goldens.log", "goldens", "tests/golden/dump_goldens.sh --check", r"^(goldens )(match)$")

MUT_DOMAINS = {"drift", "tamper", "verifier", "immutable"}
mut = [r for r in S12 + S13 if r.get("domain") in MUT_DOMAINS or re.search(r":(D07\.(7|8|9|10|11)|D01\.[45]|D04\.F[1-5]|E09\.mutation|T\d)", r["test_id"])] \
      + [r for r in RR if "mutant" in r["test_id"]] + SST + [r for r in E2E if re.search(r"Tamper|Artifacts|resealed|truncated|Coverage", r["test_id"])]
for r in mut: r["expected"] = "mutation DETECTED or REJECTED"
fail_inj = [r for r in S12 if ":D04.F" in r["test_id"]]
anchor = [r for r in S13 if r.get("domain") in {"anchor", "coverage", "freshness", "export", "golden"}] + [r for r in E2E if "Coverage" in r["test_id"] or "Artifacts" in r["test_id"] or "HappyPath" in r["test_id"]]
extv = E2E + RPC + DENO

def dump(name, rows):
    json.dump(dict(commit_sha=sha, environment=ENV, totals={s: sum(1 for r in rows if r["status"] == s) for s in ("PASS", "FAIL", "BLOCKED")}, results=rows), open(os.path.join(OUT, name), "w"), indent=1)
    return rows

allrows = {}
allrows["behavioral"] = dump("behavioral-results.json", S12 + S13 + REG + STAT + GOLD)
allrows["concurrency"] = dump("concurrency-results.json", RR + AR)
allrows["mutation"] = dump("mutation-results.json", mut)
allrows["anchor"] = dump("anchor-verification-results.json", anchor)
allrows["failure_injection"] = dump("restoration-failure-injection.json", fail_inj)
allrows["external"] = dump("external-verifier-results.json", extv)
tot = {k: {s: sum(1 for r in v if r["status"] == s) for s in ("PASS", "FAIL", "BLOCKED")} for k, v in allrows.items()}
json.dump(tot, open(os.path.join(OUT, "totals.json"), "w"), indent=1)
print(json.dumps(tot))
bad = sum(v["FAIL"] + v["BLOCKED"] for v in tot.values())
sys.exit(1 if bad else 0)
