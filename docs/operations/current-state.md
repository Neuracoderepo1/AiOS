# AiOS baseline: current state

Status: **database migrations and Edge Function source captured; live certification NOT performed.**

## What is captured

- `supabase/migrations/`: 115 files (as of 2026-11-08), one per row of `supabase_migrations.schema_migrations` on project `jtkcdwhiduixoiodhbfn`, named `<version>_<name>.sql`, original chronology preserved. Content is the exact recorded SQL (compared by md5 after trimming trailing whitespace).
- `supabase/functions/`: source of the deployed Edge Functions, compared byte-for-byte (trailing whitespace trimmed) with the deployed source.

| Function | Deployed version |
|---|---|
| execute-task | 9 |
| invoke-tool | 5 |
| launch-mission | 5 |
| review-approval | 8 |

All four have `verify_jwt = true`.

## What this verification does and does not prove

- Proves: each migration file equals the SQL the live migration history recorded.
- Does NOT prove: that replaying the files reproduces the live catalog. Objects changed outside the migration history (dashboard edits, ad-hoc SQL) are not detected. A catalog-level diff (tables, functions, triggers, policies, grants) is part of the later certification phase.

## Observations (documented, deliberately not acted on)

- Two migration names appear twice with different versions: `restrict_platform_metrics_to_service_role` (20260822125047, 20260822125056) and `aios_grant_hygiene_and_credential_column_lockdown` (20260826133412, 20260826133828; identical content). `aios_audit_reseal_legacy_chain` / `aios_audit_reseal_after_clock` (20260825123242 / 20260825123427) are also identical in content.
- Some migrations embed environment-specific identifiers (a test auth user id, demo organization ids, one agent id). They are identifiers, not credentials, but they make a clean-room replay data-dependent.
- Several migrations contain data updates keyed to those ids and will no-op or fail on an empty database.
- Early migrations (001-010) use unqualified table names and later ones move logic into a `private` schema; replay order matters.
- `aios_platform_metrics()` grants flipped several times (anon restored 20260824094834, revoked again 20260831171518). Current intent for anonymous landing-page use should be confirmed before certification.
- Secrets are not stored in the repository. `ANTHROPIC_API_KEY` is read from Edge Function secrets at runtime.

## Approval convergence (2026-11-02)

- `private.aios_expire_stale_approvals()` validates organization bindings first (`private.aios_approval_binding_defect`), skips and reports invalid records untouched, isolates each transition in a subtransaction, and appends a `manual_review` disposition (append-only). Live as migration `20261101232313` (captured in this repo).
- `public.aios_backlog_effective_dispositions` resolves the latest disposition per entity. Private-schema tables have deny-by-default RLS (invariant 9).
- Production applied 2026-11-02 via the Supabase connector, so production versions for the view/RLS migrations carry connector timestamps, not the repo filenames.
- Open: one pending approval with a cross-organization agent binding (quarantined, owner review); two queued manual-review items (owner decision); audit-chain verification on production data not yet run (service-role only). The 46-case matrix and G4 concurrency run on every CI run against a replay and are green on `main`; that is replay evidence, not live certification. AiOS remains open for production certification.

## Audit TRUNCATE guard (2026-11-06)

- Applied to production and captured as migration `20261106193358_aios_execution_gate_cascade_and_audit_truncate_guard.sql`: `service_role` no longer holds TRUNCATE on `public.aios_audit_events` and `trg_aios_audit_no_truncate` blocks it. Verified read-only on 2026-11-08 (privilege false, trigger present). Smoke check S11 reports PASS in this state.
