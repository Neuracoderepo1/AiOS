# AiOS budget-neutral logical export and isolated restore

## Status and scope

This procedure provides a budget-neutral logical-export path and a local PostgreSQL restore path. It is not Supabase managed backup, PITR, a production backup service, or proof of a production recovery point. It does not meet an RPO/RTO until an owner-authorized export cadence and measured restore exercises are established.

The scripts are:
- `scripts/recovery/export_logical.sh`
- `scripts/recovery/restore_local.sh`
- `scripts/recovery/validate_local_restore.sh`
- Safety self-tests: `tests/recovery/test_scripts.sh`
- Disposable real-PostgreSQL roundtrip: `tests/recovery/postgres_roundtrip.sh` (invoked by AiOS CI after the local Supabase migration replay)

The exporter creates a PostgreSQL custom-format database archive, a schema-only SQL export, an extension inventory, source metadata, a readable archive listing, and a SHA-256 manifest. It refuses to write into the Git working tree. The restore script only targets loopback PostgreSQL and a database named `aios_restore_*`; it requires an empty, pre-created database.

## Security requirements

1. Keep database exports outside the repository and outside synchronized/public folders.
2. Use encrypted local storage with access restricted to the database owner and authorized recovery operators.
3. Never paste credentials into shell commands, tickets, logs, CI output, or repository files.
4. Supply credentials through a `PGPASSFILE` with permissions 0600 or stricter. Do not put passwords in `PGPASSWORD` or connection-string command arguments.
5. Use a direct database endpoint with TLS where supported; set `PGSSLMODE=require` for hosted connections.
6. Treat the custom archive as sensitive: it can contain all dumpable application data, including private tenant data.
7. A production export requires a separate explicit owner approval identifying the project, purpose, scope, destination, retention, operator, and approval/ticket ID. The script's marker is only a guardrail, not a substitute for that approval.
8. No production export has been performed as part of this engineering work.

## Prepare libpq credentials

Create a password file outside the repository, for example `$HOME/.config/aios/pgpass`, with one line in PostgreSQL password-file format:

```text
hostname:5432:database_name:database_user:password
```

Escape colons and backslashes in fields according to PostgreSQL `.pgpass` rules, then restrict access:

```sh
chmod 600 "$HOME/.config/aios/pgpass"
```

Export non-secret connection parameters into the current shell. Do not use a connection URI:

```sh
export PGHOST='approved-database-host'
export PGPORT='5432'
export PGUSER='approved-database-user'
export PGDATABASE='approved-database-name'
export PGPASSFILE="$HOME/.config/aios/pgpass"
export PGSSLMODE='require'
```

## Create a logical export

For a disposable non-production environment on loopback only:

```sh
export AIOS_EXPORT_APPROVAL='NONPRODUCTION'
bash scripts/recovery/export_logical.sh "$HOME/secure-backups/aios"
```

For a remote non-production environment, obtain an explicit owner approval and set `OWNER_APPROVED_NONPRODUCTION:<approval-id>`. For production, do not proceed unless the separate owner approval described above exists and covers this exact operation; then set `OWNER_APPROVED_PRODUCTION:<approval-id>` and run the same script into the approved encrypted destination. The plain `NONPRODUCTION` marker is rejected for non-loopback hosts and when a remote `PGHOSTADDR` or libpq service override is configured. Do not store the export in this repository. The script will create a new `aios-logical-export` directory and refuse to overwrite an existing export.

The script checks command exit status, non-empty artifacts, archive readability, and writes SHA-256 hashes for all generated artifacts. Verify the manifest immediately:

```sh
cd "$HOME/secure-backups/aios/aios-logical-export"
sha256sum -c SHA256SUMS
```

On macOS, use `shasum -a 256 -c SHA256SUMS` if `sha256sum` is unavailable. Preserve the manifest with the archive. Store a second copy of the manifest separately if operational policy permits, but never expose data or credentials.

## Restore into isolated local PostgreSQL

Use a disposable local PostgreSQL instance, not the hosted project. Install compatible PostgreSQL client/server versions and confirm that every required extension binary/control file is available locally. Read `extensions.tsv` from the export. Do not pre-create extensions in the target database before running the restore script: the archive may contain extension creation entries, and the target must remain empty. The restore will fail closed if the extension cannot be created from the archive. Supabase-specific/provider-managed extensions may not be available in a generic local PostgreSQL installation; use a compatible local Supabase stack or classify that dependency as external.

Create a fresh empty database with a name beginning `aios_restore_`. Example:

```sh
createdb aios_restore_20261113
```

Configure local libpq variables, using a local-only password file:

```sh
export PGHOST='127.0.0.1'
export PGPORT='5432'
export PGUSER='local-postgres-user'
export PGDATABASE='aios_restore_20261113'
export PGPASSFILE="$HOME/.config/aios/local-pgpass"
unset PGSSLMODE
```

Restore and validate:

```sh
bash scripts/recovery/restore_local.sh "$HOME/secure-backups/aios/aios-logical-export"
bash scripts/recovery/validate_local_restore.sh "$HOME/secure-backups/aios/aios-logical-export"
```

The restore script verifies the archive checksums, confirms the target is loopback and uses the `aios_restore_*` prefix, refuses non-empty targets, and runs `pg_restore` in a single transaction. It does not drop or recreate a database.

The structural validator checks that application tables and RLS-enabled public tables exist, that audit-event protection triggers exist, that an audit-chain verifier function exists, and that all source extensions are installed. This is a structural check, not a full application acceptance test or cryptographic audit-chain PASS. Follow it with the repository's PostgreSQL SQL, concurrency, audit-chain, and application smoke suites against the restored database.

## What logical exports do not provide

- No continuous WAL archive or point-in-time recovery.
- No guarantee of a zero-data-loss recovery point.
- No automatic backup schedule, retention enforcement, off-site replication, or immutable storage.
- No global role/password dump. Database roles, grants outside the dumped database, secrets, Edge Function environment variables, provider configuration, and external trust-anchor keys require separate controlled reconstruction.
- Extension binaries must exist on the restore server. Extension SQL metadata alone cannot install provider-managed binaries.
- pg_cron extension presence does not prove scheduled jobs are restored or correct. Reconstruct and verify schedules from reviewed migrations/configuration; never copy production secrets into a local test.
- Supabase Auth/provider configuration and external services need separate recovery procedures.
- An export checksum proves artifact integrity against its manifest, not completeness, authenticity of the source, or restorability.

## Required restore evidence record

For every exercise, retain:
- Source environment classification (non-production or owner-approved production), project identifier, database version, and export timestamp.
- Exact repository commit/migration watermark.
- pg_dump/pg_restore client versions.
- Artifact names, byte sizes, and SHA-256 values.
- Extension comparison and any provider-specific dependencies.
- Restore start/end times and exit codes.
- Structural validation output.
- SQL regression, concurrency, audit-chain verification, and application smoke results.
- Cron schedule reconstruction evidence.
- Measured restore duration and observed data-loss window, if the source export timestamp is trustworthy.

Do not claim RPO/RTO compliance until repeated exercises establish measured values and an owner approves target objectives.

## Current AiOS plan limitation

The current Supabase Free plan does not include scheduled project backups. Daily backups are included with Pro. PITR requires Pro plus a paid add-on. No upgrade or add-on purchase is authorized. This logical export workflow is a budget-neutral alternative with manual execution and explicit limitations; it is not equivalent to managed backups or PITR.

## Rollback and cleanup

A failed restore is isolated to the disposable local `aios_restore_*` database. Preserve logs without credentials, inspect the failure, and discard/recreate only that disposable local database after confirming its exact name and host. Never point cleanup commands at a hosted endpoint. The export directory is immutable input to restore; do not modify it. If a checksum fails, quarantine the export and obtain a new authorized export rather than editing the manifest.

## Operational acceptance status

The safety self-test covers refusal paths and shell syntax. The CI roundtrip creates a disposable source database, inserts synthetic fixture rows, exports it, restores into a separate loopback-only database, validates structure/extensions, and compares row counts. A successful run proves the scripts' mechanics on the CI PostgreSQL fixture only. It does not prove a production export, full hosted AiOS database compatibility, provider-specific extension reconstruction, real audit-chain correctness, cron reconstruction, owner-context verification, or measured RPO/RTO. Production recovery readiness remains NOT VERIFIED until an owner-authorized export and restore exercise is performed against a properly approved recovery environment.
