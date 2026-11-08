# Production smoke tests

| File | Purpose | Safe on production? |
|---|---|---|
| `scripts/smoke/smoke_readonly.sql` + `run_smoke.sh` | 24 read-only checks (S00-S23): read-only proof, cron, expiry backlog, triggers, RLS, grants, SECURITY DEFINER, private-function EXECUTE, owner-decision record, migration history | Yes (single SELECT; the runner requests a read-only session and refuses to pass unless S00 proves it) |
| `scripts/smoke/post_proposal_001_verify.sql` | Verifies proposal 001 after an approved apply (`SMOKE_MODE=post001`) | Yes (read-only) |
| `scripts/smoke/nonprod_truncate_guard_test.sql` | Behavioural TRUNCATE attempt | **No. Throwaway database only** (needs `-c smoke.nonprod=1`, refuses if the guard trigger is absent) |
| `scripts/smoke/selftest.sh` | 86 cases proving each check goes red for the defect it targets, plus the runner's fail-closed behaviour | Throwaway database only (superuser; every mutation is rolled back). Runs in CI |

## Run
```
DATABASE_URL=<read-only connection string> scripts/smoke/run_smoke.sh
SMOKE_PROPOSAL_001_APPLIED=1 scripts/smoke/run_smoke.sh     # after proposal 001: S11 must PASS
SMOKE_MODE=post001 scripts/smoke/run_smoke.sh               # P1-P6 verification
SMOKE_PROFILE=replay scripts/smoke/run_smoke.sh             # throwaway DB: production-only S20 becomes INFO
```
The connection string is exported as `PGDATABASE` for libpq and is never passed as an argument (argv is visible to local users) or printed.
The runner exits 0 only if every expected row is present exactly once, every status is PASS/WARN/INFO, S00 is PASS, and no row is FAIL. A missing object is a FAIL row, not a query error. A psql error is never a pass.

Status meanings: FAIL = control broken. WARN = documented exception (S22 leaked-password protection; S11 only if the audit TRUNCATE guard is absent, which it no longer is in production or in migrations since 20261106193358). INFO = context.

## What a PASS does and does not mean
- S09/S10 look for an enabled BEFORE-row UPDATE/DELETE trigger that is not an INSERT-OR-UPDATE validator. They prove a guard of that shape exists, not that its body rejects the write; `tests/sql` covers behaviour on replay, and `nonprod_truncate_guard_test.sql` does for TRUNCATE.
- S05 tolerates 10 minutes of cron lag and exempts approvals covered by an `owner_decision_retain` disposition.
- Not covered: audit-chain hash verification (service-role only, NOT VERIFIED), write-path/lifecycle tests on production (each needs its own owner approval), and alerting (no monitoring exists yet).

## Changes from the Agent 004 patch (commit c75501e)
Proven by `selftest.sh`; the original passes every one of these defects: NULL-`expires_at` stale approvals (S05), replica-only triggers (S07), audit UPDATE guard disabled (S09, satisfied by an unrelated INSERT-OR-UPDATE validator), duplicate cron job (S01), anon TRUNCATE (S15); and its runner returned 0 on a FAIL row followed by >1 MB of output (`echo | grep -q` SIGPIPE under `pipefail`). Added S00 and S23; `to_regprocedure`/`to_regclass` in S18, S19, P4, P5.

Baseline: `docs/certification/smoke-baseline-2026-11-02.md` (taken with the original 22 checks; superseded by the 2026-11-06 production run recorded in the PR).
