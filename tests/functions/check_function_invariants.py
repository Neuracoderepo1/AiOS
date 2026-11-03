#!/usr/bin/env python3
"""Static regression guard for Edge Function ordering and integrity rules (runs without Deno or a database).

Invariants (each failure names the file and rule):
  O1  execute-task and launch-mission authenticate (auth.getUser) before reading ANTHROPIC_API_KEY.
  O2  execute-task checks ANTHROPIC_API_KEY before its first state mutation (the task claim) and after task/org/agent validation.
  O3  execute-task claims the task BEFORE it moves the mission to running.
  O4  launch-mission performs no database write (insert/update) before the plan has been produced and validated.
  O5  launch-mission never coerces a missing or invalid model risk_level to a default.
  O6  launch-mission inserts all tasks in a single statement and compensates a failed task insert without deleting the mission.
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parents[2] / "supabase" / "functions"
et = (root / "execute-task" / "index.ts").read_text()
lm = (root / "launch-mission" / "index.ts").read_text()
failures = []

def pos(text, pattern, start=0):
    m = re.compile(pattern, re.S).search(text, start)
    return m.start() if m else -1

def check(ok, msg):
    if not ok:
        failures.append(msg)

# O1
for name, text in (("execute-task", et), ("launch-mission", lm)):
    g, k = pos(text, r"auth\.getUser\("), pos(text, r"Deno\.env\.get\(\s*[\"']ANTHROPIC_API_KEY[\"']\s*\)")
    check(g >= 0 and k >= 0 and g < k, f"O1 {name}: getUser must come before ANTHROPIC_API_KEY")

# O2 / O3
k = pos(et, r"Deno\.env\.get\(\s*[\"']ANTHROPIC_API_KEY[\"']\s*\)")
member = pos(et, r"aios_is_org_member")
agent_susp = pos(et, r"Agent is suspended")
claim = pos(et, r"from\(\"aios_tasks\"\)\.update\(\{ status: \"running\"")
mission = pos(et, r"from\(\"aios_missions\"\)\.update\(\{ status: \"running\"")
check(member >= 0 and agent_susp >= 0 and k > agent_susp > member, "O2 execute-task: API-key check must follow org/agent validation")
check(claim > k, "O2 execute-task: API-key check must precede the task claim (first mutation)")
check(claim >= 0 and mission > claim, "O3 execute-task: task claim must precede mission start")

# O4
first_write = min([p for p in (pos(lm, r"from\('aios_missions'\)\.insert"), pos(lm, r"from\('aios_tasks'\)\.insert")) if p >= 0] or [-1])
plan_done = pos(lm, r"validatePlan\(drafts\)")
check(plan_done >= 0 and first_write > plan_done, "O4 launch-mission: mission/task writes must follow plan validation")

# O5
check(not re.search(r"risk_level\)\s*\?\s*d\.risk_level\s*:\s*['\"]low['\"]", lm), "O5 launch-mission: invalid risk_level must not default to 'low'")
check("Model returned an invalid risk_level" in lm, "O5 launch-mission: invalid risk_level must be rejected with an error")

# O6
check(len(re.findall(r"from\('aios_tasks'\)\.insert", lm)) == 1 and "plan.map(" in lm, "O6 launch-mission: tasks must be inserted in one statement")
check("status:'cancelled'" in lm and not re.search(r"from\('aios_missions'\)\.delete", lm), "O6 launch-mission: failed task insert must cancel (not delete) the mission")

if failures:
    print("\n".join("FAIL " + f for f in failures)); sys.exit(1)
print("ok: edge function invariants O1-O6")
