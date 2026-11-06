#!/usr/bin/env python3
"""Negative tests for the behavioral harness: break the Edge Functions on purpose and require the suite to notice.

For each mutant this copies supabase/functions to a temp dir, applies a deliberate regression, re-runs the SAME behavioral
suite against the copy (FUNCTIONS_DIR), and requires that the tests named in `must_fail` actually FAIL. A harness that
cannot fail proves nothing; this proves it can, and that it fails for the right reason.

A mutant is only counted as DETECTED when all of these hold:
  * every edit matched exactly once (a drifted pattern is an error, never a silent no-op),
  * the mutated code still loads (the "load under the import map" test passes), so detection is not just a crash,
  * every substring in must_fail matches at least one FAILED test name.
A control run against an UNMODIFIED copy must pass fully, which proves the FUNCTIONS_DIR override itself is sound.

Usage:
  python3 tests/functions/behavioral/run_mutants.py [--runner "<command>"] [--json out.json]
Default runner is the Node fallback; for Deno use e.g.
  --runner "deno test --import-map=tests/functions/behavioral/import_map.json --allow-env --allow-read tests/functions/behavioral/"
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
FUNCS = REPO / "supabase" / "functions"
DEFAULT_RUNNER = "node --no-warnings tests/functions/behavioral/node/run.mjs"
LOADER_TEST = "load under the import map"
ANSI = re.compile(r"\x1b\[[0-9;]*m")
FAILED_LINE = re.compile(r"^(.*?) \.\.\. FAILED")

LM = "launch-mission/index.ts"
ET = "execute-task/index.ts"

MUTANTS = [
    # ---- launch-mission -------------------------------------------------------------------------------------------------
    dict(id="LM1", file=LM, why="invalid model risk level is coerced to 'low' instead of rejected",
         edits=[("if(typeof r!=='string'||!(RISK_LEVELS as readonly string[]).includes(r))return{error:'Model returned an invalid risk_level'};", ""),
                ("plan.push({title:t,instructions:i,risk_level:r as RiskLevel});", "plan.push({title:t,instructions:i,risk_level:((RISK_LEVELS as readonly string[]).includes(r as string)?r:'low') as RiskLevel});")],
         must_fail=['invalid model risk_level "critical"', "second task has an invalid risk level"]),
    dict(id="LM2", file=LM, why="mission row is written BEFORE planning/validation",
         edits=[("let plan:PlannedTask[];", "let plan:PlannedTask[];await admin.from('aios_missions').insert({organization_id,title,objective,status:'queued'});")],
         must_fail=["no database writes when planning fails: model network failure", "no database writes when planning fails: model returns non-JSON text", "503 with zero writes"]),
    dict(id="LM3", file=LM, why="failed task insert no longer compensates the mission to 'cancelled'",
         edits=[(".update({status:'cancelled',metadata:{creation_failed:true", ".update({status:'queued',metadata:{creation_failed:true")],
         must_fail=["compensated to 'cancelled'"]),
    dict(id="LM4", file=LM, why="mission_creation_failed audit drops the failure reason",
         edits=[("reason:String(reason).slice(0,500),compensated:!ce", "compensated:!ce")],
         must_fail=["audit event records stage, reason and compensated=true"]),
    dict(id="LM5", file=LM, why="compensation_error is omitted from the audit when compensation fails",
         edits=[(",...(ce?{compensation_error:String(ce.message).slice(0,500)}:{})", "")],
         must_fail=["compensation failure is reported, not hidden"]),
    dict(id="LM6", file=LM, why="compensation failure is swallowed silently (no console.error)",
         edits=[("if(ce)console.error(`[launch-mission] compensation failed for mission ${mission.id}: ${ce.message}`);", "")],
         must_fail=["compensation failure is reported, not hidden"]),
    dict(id="LM7", file=LM, why="tasks inserted one-by-one instead of one atomic statement",
         edits=[("const {data:tasks,error:te}=await admin.from('aios_tasks').insert(plan.map(t=>({organization_id,mission_id:mission.id,assigned_agent_id:selected.id,title:t.title,instructions:t.instructions,risk_level:t.risk_level,status:'queued'}))).select('*');",
                 "let tasks:any[]=[];let te:any=null;for(const t of plan){const r1=await admin.from('aios_tasks').insert([{organization_id,mission_id:mission.id,assigned_agent_id:selected.id,title:t.title,instructions:t.instructions,risk_level:t.risk_level,status:'queued'}]).select('*');if(r1.error){te=r1.error;break}tasks.push(...(r1.data??[]))}")],
         must_fail=["ONE insert statement"]),
    dict(id="LM8", file=LM, why="session validation removed (authentication no longer precedes the API-key check)",
         edits=[("if(ue||!u?.user)return json({error:'Invalid or expired session'},401);", "")],
         must_fail=["authentication happens BEFORE API-key validation"]),
    dict(id="LM9", file=LM, why="API-key check hoisted above organization authorization",
         edits=[("const {data:member}=await user.rpc(", "if(!Deno.env.get('ANTHROPIC_API_KEY'))return json({error:'AI dependency unavailable'},503);const {data:member}=await user.rpc(")],
         must_fail=["org authorization happens BEFORE API-key validation", "deterministic support objective needs no API key"]),
    # ---- execute-task ---------------------------------------------------------------------------------------------------
    dict(id="ET1", file=ET, why="API-key check hoisted above authentication",
         edits=[('const supabaseUrl = Deno.env.get("SUPABASE_URL")!;', 'if (!Deno.env.get("ANTHROPIC_API_KEY")) return json({ error: "ANTHROPIC_API_KEY is not configured" }, 503);\n  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;')],
         must_fail=["authentication happens BEFORE API-key validation"]),
    dict(id="ET2", file=ET, why="API-key check hoisted above the idempotent-replay path",
         edits=[('if (!["queued", "approved"].includes(task.status)) {', 'if (!Deno.env.get("ANTHROPIC_API_KEY")) return json({ error: "ANTHROPIC_API_KEY is not configured; refusing to fake agent execution" }, 503);\n  if (!["queued", "approved"].includes(task.status)) {')],
         must_fail=["idempotent replay of a succeeded invocation works WITHOUT an API key"]),
    dict(id="ET3", file=ET, why="mission is started BEFORE the task is claimed",
         edits=[("// Task: atomic compare-and-set", 'await admin.from("aios_missions").update({ status: "running", started_at: new Date().toISOString() }).eq("id", task.mission_id).eq("status", "queued");\n  // Task: atomic compare-and-set')],
         must_fail=["claimed BEFORE the mission is started", "a LOST claim"]),
    dict(id="ET4", file=ET, why="task claim is no longer a compare-and-set on status",
         edits=[('.eq("id", task.id).eq("status", task.status).select("id");', '.eq("id", task.id).select("id");')],
         must_fail=["claim is a compare-and-set", "a LOST claim", "task CANCELLED between read and claim"]),
    dict(id="ET5", file=ET, why="mission-start failure no longer fails the claimed task",
         edits=[('await failClaimed("mission_start", missionStartError.message, { tool_executed: false });', "")],
         must_fail=["mission-start failure -> 500, task FAILED"]),
    dict(id="ET6", file=ET, why="failed stage / last_error diagnostics dropped from failed tasks",
         edits=[("if (stage) {", "if (false) {")],
         must_fail=["mission-start failure -> 500, task FAILED", "model failure after the claim"]),
    dict(id="ET7", file=ET, why="a lost task claim is ignored and execution continues",
         edits=[('if (!taskClaimed || taskClaimed.length !== 1) return json({ error: "Task was already claimed by another execution", task_id: task.id }, 409);', "")],
         must_fail=["a LOST claim"]),
    dict(id="ET8", file=ET, why="task failure no longer fails the mission",
         edits=[('const { error: missionErr } = await admin.from("aios_missions").update({ status: "failed", completed_at: new Date().toISOString() }).eq("id", task.mission_id).eq("status", "running");',
                 "const missionErr = null as { message: string } | null;")],
         must_fail=["task AND mission end 'failed'"]),
    # ---- terminal-state / cancellation-race guards (added with terminal_and_race_test.ts) -------------------------------
    dict(id="ET9", file=ET, why="task failure overwrites the mission without the status = running guard (cancelled/terminal missions rewritten)",
         edits=[('const { error: missionErr } = await admin.from("aios_missions").update({ status: "failed", completed_at: new Date().toISOString() }).eq("id", task.mission_id).eq("status", "running");',
                 'const { error: missionErr } = await admin.from("aios_missions").update({ status: "failed", completed_at: new Date().toISOString() }).eq("id", task.mission_id);')],
         must_fail=["mission CANCELLED while the task runs is not overwritten", "'completed' mission row is never modified"]),
    dict(id="ET10", file=ET, why="mission start loses its status = queued guard (cancelled/terminal missions resurrected to running)",
         edits=[('.eq("id", task.mission_id).eq("status", "queued").select("id");', '.eq("id", task.mission_id).select("id");')],
         must_fail=["not resurrected to 'running'", "'cancelled' mission row is never modified"]),
    dict(id="ET11", file=ET, why="task failure recording loses its status = running guard (a cancelled task is overwritten to failed)",
         edits=[('.update(patch).eq("id", task.id).eq("status", "running");', '.update(patch).eq("id", task.id);')],
         must_fail=["task cancelled WHILE running is never overwritten"]),
    dict(id="LM10", file=LM, why="mission compensation loses its status = queued guard (a concurrent cancellation is overwritten)",
         edits=[("reason:String(reason).slice(0,500)}}).eq('id',mission.id).eq('status','queued');", "reason:String(reason).slice(0,500)}}).eq('id',mission.id);")],
         must_fail=["CANCELLED concurrently before compensation keeps the canceller's metadata", "compensation only touches a mission that is still 'queued'"]),
]


def run_suite(runner: str, functions_dir: Path):
    env = dict(os.environ, FUNCTIONS_DIR=str(functions_dir), NO_COLOR="1")
    p = subprocess.run(shlex.split(runner), cwd=REPO, env=env, capture_output=True, text=True, timeout=600)
    out = ANSI.sub("", p.stdout + "\n" + p.stderr)
    failed = [m.group(1).strip() for line in out.splitlines() if (m := FAILED_LINE.match(line))]
    return p.returncode, failed, out


def make_copy(root: Path) -> Path:
    dest = root / "functions"
    shutil.copytree(FUNCS, dest)
    return dest


def apply_edits(copy: Path, file: str, edits):
    path = copy / file
    text = path.read_text()
    for find, repl in edits:
        n = text.count(find)
        if n != 1:
            raise SystemExit(f"mutation pattern matched {n} times (need exactly 1) in {file}: {find[:90]!r}")
        text = text.replace(find, repl)
    path.write_text(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runner", default=DEFAULT_RUNNER)
    ap.add_argument("--json", default=None, help="write a machine-readable summary here")
    args = ap.parse_args()

    results = []
    with tempfile.TemporaryDirectory(prefix="aios-mutants-") as tmp:
        tmp = Path(tmp)
        control_dir = make_copy(tmp / "control")
        code, failed, out = run_suite(args.runner, control_dir)
        control_ok = code == 0 and not failed
        print(f"CONTROL (unmodified copy via FUNCTIONS_DIR): {'PASS' if control_ok else 'FAIL'}  exit={code} failed={len(failed)}")
        if not control_ok:
            print(out[-3000:])
            sys.exit(2)

        for m in MUTANTS:
            copy = make_copy(tmp / m["id"])
            apply_edits(copy, m["file"], m["edits"])
            code, failed, out = run_suite(args.runner, copy)
            loads = not any(LOADER_TEST in f for f in failed)
            missing = [s for s in m["must_fail"] if not any(s in f for f in failed)]
            detected = code != 0 and loads and not missing
            results.append(dict(id=m["id"], file=m["file"], why=m["why"], detected=detected, exit=code, loads=loads,
                                failed_count=len(failed), missing_expected=missing, failed_tests=failed))
            status = "DETECTED" if detected else "SURVIVED/INVALID"
            print(f"{m['id']:4} {status:16} {len(failed):2} test(s) failed  | {m['why']}")
            if not detected:
                print(f"       exit={code} loads={loads} expected-but-not-failed={missing}")

    survivors = [r for r in results if not r["detected"]]
    print(f"\n{len(results) - len(survivors)}/{len(results)} mutants detected; control passes: {control_ok}")
    if args.json:
        Path(args.json).write_text(json.dumps(dict(control_ok=control_ok, mutants=results), indent=2))
    sys.exit(1 if survivors else 0)


if __name__ == "__main__":
    main()
