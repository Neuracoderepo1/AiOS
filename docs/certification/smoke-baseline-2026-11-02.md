# Smoke baseline: production `jtkcdwhiduixoiodhbfn`, read-only, 2026-11-02 ~21:15 UTC (last cron run 21:15:00)
Suite: `scripts/smoke/smoke_readonly.sql` sha256 `ddc7d4da99f874e3c8f206c2e74072ee1220e4f82a6ca0d7b784bb69ef382f8f`; repo base d762f27 plus branch agent-004/aios-final-certification. Executed through the Supabase SQL tool (read-only), not via run_smoke.sh.
Result: **17 PASS, 0 FAIL, 2 WARN, 3 INFO.**

| Status | Checks |
|---|---|
| PASS | S01 cron jobs 1 and 2 active */5; S02 cron liveness (last run 21:15:00); S03 0 failures in last 60 min; S05 0 stale pending; S07 0 disabled triggers; S08 5/5 approval integrity triggers; S09 audit UPDATE guard; S10 audit DELETE guard; S12 RLS on all tables; S13 definer search_path pinned; S14 anon no definer exec; S15 anon no public table privileges; S16 no client privileges on private tables; S17 no authenticated writes on approvals/audit/invocations; S18 expiry function definer + pinned; S19 view security_invoker; S20 retain record present |
| WARN | S11 audit TRUNCATE not blocked (service_role has TRUNCATE) until proposal 001; S22 leaked-password protection disabled (manual) |
| INFO | S04 24h cron: succeeded=563 failed=13 (all failures Nov 1 22:20-23:20 UTC, pre-fix); S06 approvals pending=1 expired=22 approved=4 rejected=1; S21 111 migrations, latest 20261102064034 |
