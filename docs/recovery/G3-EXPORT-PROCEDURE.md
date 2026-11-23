# G3 Logical Export Procedure

**Status:** PREPARATION ONLY. Production export: NOT AUTHORIZED / NOT STARTED.

## Existing repository tooling

- `scripts/recovery/export_logical.sh` creates the custom-format logical archive and supporting schema/extension/source metadata.
- `scripts/recovery/encrypt_artifact.sh` encrypts an already-created artifact with age.
- `scripts/recovery/verify_manifest.sh` verifies the SHA-256 manifest.
- Existing `docs/operations/LOGICAL-EXPORT-RESTORE.md` documents exporter safeguards and PostgreSQL client prerequisites.

## Hard preconditions

Do not run the production exporter until all items in `G3-AUTHORIZATION-CHECKLIST.md` are PASS or explicitly owner-acknowledged where the checklist allows acknowledgement. In particular, destination, operator, ticket, jurisdiction, encryption key custody, transfer, retention, isolated target and RPO/RTO disposition must be recorded. Agent 003 must review the exact scripts and evidence package before export. Human Director must separately approve the exact export operation and source scope.

The exporter approval marker is a technical guard, not an authorization system. It must never be treated as evidence of owner approval by itself.

## Non-mutating dry-run

Before any export operation, the operator may run the exporter in configuration-only mode against an existing empty destination directory. This validates required environment fields, approval marker syntax, password-file permissions, executable availability, and destination safety. It does not connect to PostgreSQL, create an export directory, or invoke `pg_dump`/`psql`:

```sh
bash scripts/recovery/export_logical.sh --dry-run "$HOME/secure-backups/aios"
```

The dry-run is not an export, a source connectivity check, or an authorization substitute. Use only an already-existing destination directory.

## Controlled sequence after approval

1. Record the approved ticket, named operator, exact project ID, source environment identity, scope, expected database version and source endpoint classification in the owner-controlled execution record.
2. Confirm the local workspace is encrypted, non-synchronized, access-restricted and has sufficient free space for archive, temporary files and encrypted output.
3. Verify PostgreSQL client versions and TLS requirements. Supply credentials only through a protected `PGPASSFILE` with mode 0600 or stricter. Never use `PGPASSWORD`, URI passwords, command-line passwords or shell tracing.
4. Run exporter only with the exact approved environment marker and destination path described in `docs/operations/LOGICAL-EXPORT-RESTORE.md`. Never use dry-run as proof of export.
5. Confirm all exporter exit codes, archive readability, schema-only output, extension inventory, metadata and non-zero sizes. Stop on any warning or incomplete output.
6. Encrypt the archive and every sensitive export sidecar with the owner-approved age recipient. Public/non-sensitive inventory may be retained separately only after review.
7. Generate and verify SHA-256 manifests for every ciphertext artifact. Preserve the manifest separately under owner custody.
8. Upload ciphertext only to the approved restricted Drive folder. Never upload plaintext, private identity files, credential files or temporary workspaces.
9. Download ciphertext to a separate verification directory, verify manifest, then perform an authorized decryption and isolated restore.
10. Record timestamps, byte sizes, hashes, command versions, exit codes and operator identity in a controlled evidence record. Do not record credentials or sensitive row contents.

## Stop conditions

Stop and preserve evidence if approval is missing, source identity differs, destination access is uncertain, local disk is insufficient, encryption fails, manifest mismatch occurs, transfer channel is not approved, export is incomplete, archive listing fails, or any command attempts an unexpected production write. Do not retry against production until the cause is reviewed.

## Current state

No production export, production download, encryption of production data, or Drive upload has occurred. This is a procedure only. G3 remains BLOCKED.
