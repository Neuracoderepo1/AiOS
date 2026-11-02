# Production smoke tests

| File | Purpose | Safe on production? |
|---|---|---|
| `scripts/smoke/smoke_readonly.sql` + `run_smoke.sh` | 22 read-only checks: cron, expiry, triggers, RLS, grants, SECURITY DEFINER, owner-decision record, migration history | Yes (single SELECT; the runner forces `default_transaction_read_only=on`) |
| `scripts/smoke/post_proposal_001_verify.sql` | Verifies proposal 001 after an approved apply | Yes (read-only) |
| `scripts/smoke/nonprod_truncate_guard_test.sql` | Behavioural TRUNCATE attempt | **No. Throwaway database only** |

Run: `DATABASE_URL=<read-only connection string> scripts/smoke/run_smoke.sh` (the URL is never printed or stored). Needs read access to `cron`, `supabase_migrations` and the `public`/`private` catalogs. Exit 1 on any FAIL. WARN and INFO never fail the run and must be reported.

Status meanings: FAIL = control broken. WARN = documented exception (S11 audit TRUNCATE gap until proposal 001; S22 leaked-password protection). INFO = context.
Not covered: audit-chain hash verification (service-role only, NOT VERIFIED), write-path/lifecycle smoke tests on production (each requires its own owner approval), and alerting (no monitoring exists yet).
Baseline: `docs/certification/smoke-baseline-2026-11-02.md`.
