# AiOS baseline: current state

Status: **database migrations and Edge Function source captured; live certification NOT performed.**

## What is captured

- `supabase/migrations/`: 96 files, one per row of `supabase_migrations.schema_migrations` on project `jtkcdwhiduixoiodhbfn`, named `<version>_<name>.sql`, original chronology preserved. Content is the exact recorded SQL (compared by md5 after trimming trailing whitespace).
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
