# G3 Isolated Restore Procedure

**Status:** PREPARATION ONLY. No production artifact has been restored.

## Approved target boundary

The only currently documented target class is a newly created local PostgreSQL database on loopback, with database name beginning `aios_restore_`. It must be a disposable instance isolated from production and unrelated applications. Do not restore to a Supabase hosted project or any remote endpoint.

The existing `scripts/recovery/restore_local.sh` and `validate_local_restore.sh` enforce loopback and target-name checks, verify the export manifest and use a single-transaction restore. Both require an absolute, existing, non-symlink export source directory outside the repository and an absolute, regular, non-symlink `PGPASSFILE` outside the repository with permissions 0600 or stricter. Review the exact scripts at the PR head before any production recovery exercise.

## Sequence

1. Download ciphertext into a restricted, non-synchronized restore workspace.
2. Verify the SHA-256 ciphertext manifest before decryption.
3. Decrypt using `AGE_IDENTITY_FILE` pointing to the separately held owner identity. Never put the identity contents in shell history or command arguments.
4. Verify decrypted archive readability and compare the artifact metadata with the approved export record.
5. Start a fresh isolated PostgreSQL instance with compatible major version and required extension binaries. Bind only to loopback; disable external network access where practical.
6. Create a fresh empty database named `aios_restore_<approved-run-id>`. Never reuse a database with unknown contents.
7. Set libpq environment to the loopback target and a local-only absolute `PGPASSFILE` stored outside the repository. The file must be regular, non-symlink and mode 0600 or stricter. Explicitly verify `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, and target server identity immediately before restore.
8. Run restore and structural validation scripts with the absolute export source directory outside the repository. The validator checks PostgreSQL major-version compatibility and exact extension versions. Capture exit codes and sanitized logs.
9. Run migration inventory, extension checks, schema/object inventory, indexes, constraints, function definitions, trigger enablement, grants, RLS/policies, audit-chain verification, referential checks and approved application-level tests.
10. Reconstruct cron schedules and external configuration from reviewed repository artifacts; do not copy production secrets or activate external side effects.
11. Agent 003 independently compares the evidence to acceptance criteria. Record exact restore duration and observed source timestamp.
12. Remove temporary plaintext and decrypted files only after evidence is secured and retention rules are satisfied.

## Isolation rules

- Refuse any non-loopback host or target database not prefixed `aios_restore_`.
- Refuse relative paths, repository-contained paths, symlinked source directories, symlinked PGPASS files, and source/key/artifact paths whose canonical resolution enters the repository.
- Never pass production connection variables into restore commands.
- Never reuse a production service-role key, JWT, API secret or production credentials in the isolated target.
- Disable outbound network and external integrations during restore/verification unless an individually reviewed test requires them.
- Do not start cron jobs, email delivery, payment flows, webhooks or other external side effects.
- Do not run production migration commands as part of restore validation.

## Acceptance criteria

A restore is accepted only when ciphertext integrity passes; decryption authenticates; archive integrity passes; all required extensions are available; schema/object inventories match the approved source evidence; migration watermark and expected versions are reconciled; constraints/indexes/functions/triggers/grants/RLS are checked; critical data relationships and audit chain are verified; application smoke/regression suites pass; no external side effects occurred; and Agent 003 independently accepts the exact evidence.

Synthetic CI round trips demonstrate tooling behavior only. They are not production recovery evidence.

## Current state

No local PostgreSQL server or storage capacity on the Human Director's Mac has been inspected. CI does run disposable PostgreSQL fixtures. A production-equivalent isolated restore target is therefore NOT PROVISIONED. G3 remains BLOCKED.
