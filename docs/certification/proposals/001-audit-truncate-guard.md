# Production Change Approval Package 001: block TRUNCATE on `public.aios_audit_events`

Status: **REQUIRES OWNER APPROVAL. Not applied. Prepared by Agent 004 (implementation, not certification).**
Project: `jtkcdwhiduixoiodhbfn`. Observed read-only on 2026-11-02 ~08:33 UTC. Re-run the pre-deployment checks immediately before applying.

1. **Exact SQL:** `001-audit-truncate-guard.sql` in this directory (one transaction; forward-only).
2. **Objects affected:** `public.aios_audit_events` (one privilege revoked, one trigger added); new function `private.aios_audit_no_truncate()`. No other object is modified.
3. **Current production state:** `service_role` holds INSERT, UPDATE, DELETE, TRUNCATE on the table. Existing triggers (all enabled): `trg_aios_audit_hash` (BEFORE INSERT), `trg_aios_audit_immutable_update`, `trg_aios_audit_immutable_delete`, `trg_validate_agent_org`, `trg_validate_task_org`. No TRUNCATE guard exists; row-level triggers do not fire on TRUNCATE.
4. **Expected transitions:** `service_role` loses TRUNCATE; any TRUNCATE on the table raises SQLSTATE 42501. INSERT behaviour is unchanged.
5. **Data impact:** none. No rows are read, written or deleted. No lock beyond brief catalog locks.
6. **Security impact:** closes a path where a server credential could erase the audit log. The table owner (`postgres`) can still disable triggers or truncate; that remains out of scope and is a residual risk.
7. **Pre-deployment checks (read-only):** (a) `select has_table_privilege('service_role','public.aios_audit_events','TRUNCATE')` is true; (b) the 5 triggers above are `tgenabled='O'`; (c) no job or function in the repo or `cron.job` truncates the table (`select command from cron.job`; search `supabase/migrations` and Edge Functions for `truncate`); (d) `verify_audit_chain` result recorded for the baseline if service-role access exists.
8. **Post-deployment verification:** the three queries at the foot of the SQL file; plus confirm the next two cron runs (every 5 minutes) of both jobs succeed.
9. **Rollback:** the rollback statements at the foot of the SQL file (drop trigger, drop function, re-grant). No data recovery needed.
10. **Non-production test results:** **NONE.** No equivalent environment was available to Agent 004. Required before applying: a Supabase branch or local stack built only from `supabase/migrations`, then run the SQL plus a `TRUNCATE` attempt as `service_role` and as the owner, and the full CI suite. Do not treat this item as satisfied until that evidence exists.
11. **Failure modes:** a legacy maintenance task that truncates audit events will now fail (none found in the repo); `REVOKE` is a no-op if the privilege was already removed; the migration file name/version must be added to the repo after application so history stays in parity.
12. **Historical evidence and integrity triggers:** untouched. No file under `docs/testing/evidence/` or `tests/matrix/manifest.json` changes; no existing trigger is altered, disabled or dropped.

Out of scope observation: `service_role` also holds TRUNCATE on most `public` tables. Not assessed as individually exploitable here; a follow-up proposal should decide table by table.
