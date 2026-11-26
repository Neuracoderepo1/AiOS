# G3 Encryption and Key Custody

**Status:** TOOLING PREPARED; owner key custody and production operation NOT APPROVED.

## Design

Use the maintained `age` file-encryption tool with its authenticated encryption format. Encrypt the completed PostgreSQL custom-format archive locally before any transfer. The encrypted output is the only artifact permitted to leave the local secure workspace.

Pipeline:

`pg_dump custom archive → local restricted workspace → age recipient encryption → SHA-256 of ciphertext → approved destination`

Restore:

`download ciphertext → SHA-256 verification → age identity decryption → pg_restore into isolated loopback PostgreSQL`

## Key generation and separation

Generate a new age identity on the owner's trusted device using the installed age tool:

```sh
umask 077
mkdir -p "$HOME/.config/aios-recovery"
age-keygen -o "$HOME/.config/aios-recovery/production-recovery-identity.txt"
age-keygen -y "$HOME/.config/aios-recovery/production-recovery-identity.txt" > "$HOME/.config/aios-recovery/production-recovery-recipient.txt"
chmod 600 "$HOME/.config/aios-recovery/production-recovery-identity.txt"
chmod 600 "$HOME/.config/aios-recovery/production-recovery-recipient.txt"
```

The identity file contains the private key. The recipient file contains only the public recipient. Keep both outside the repository. The scripts enforce absolute paths and reject repository-contained key files. Protect the private identity with owner-controlled offline custody and a separately stored, access-controlled recovery copy. Do not place the private identity in Google Drive with the ciphertext. Do not paste either file's contents into chat or tickets.

The sample path is illustrative. The owner must choose and verify the actual storage location and its encryption/access controls before generating a production key.

## Script interface

- Encrypt: `AGE_RECIPIENTS_FILE=/secure/owner/recipients.txt bash scripts/recovery/encrypt_artifact.sh /secure/workspace/export.dump /secure/workspace/export.dump.age`
- Verify: `bash scripts/recovery/verify_manifest.sh /secure/workspace/export.dump.age.sha256`
- Decrypt: `AGE_IDENTITY_FILE=/secure/owner/identity.txt bash scripts/recovery/decrypt_artifact.sh /secure/workspace/export.dump.age /secure/workspace/restored.dump`

The scripts require absolute paths. Inputs and recipient/identity files must be regular, non-symlink files outside the repository; ciphertext, plaintext, manifest and output paths must also resolve outside the repository, including through canonicalized parent directories. Output parent directories must already exist. The scripts reject missing dependencies, missing files, symlinks, existing output paths and invalid key-file permissions where applicable. Encryption/decryption occurs through temporary files in the destination directory with restrictive umask and atomic rename. Secrets are not command-line values and are not printed.

## Integrity and authenticity

The manifest hashes ciphertext, not plaintext. Verify it immediately after encryption, after upload/download, and before decryption. Authenticated encryption detects ciphertext modification during decryption; SHA-256 independently detects transfer/storage mismatch against the separately retained manifest. Keep a second manifest copy in a distinct owner-controlled location. A hash alone does not prove who created the artifact or that the source export was complete.

## Plaintext handling

- Export only to an owner-approved, non-synchronized, encrypted local volume with sufficient free space.
- Set restrictive directory/file permissions before export.
- Encrypt immediately after export validation.
- Never upload, email, preview, or commit plaintext exports.
- Restore plaintext only inside a verified isolated workspace.
- Remove plaintext exports and temporary decrypted files using the documented cleanup procedure after validation, subject to the owner's retention decision.
- SSD wear-leveling means file overwrite is not a reliable secure-erasure method. Prefer encrypted volumes and cryptographic erasure by destroying the relevant volume/key only after retention and recovery obligations are satisfied.

## Rotation, loss and revocation

A lost private identity makes retained ciphertext unrecoverable. Maintain two controlled private-key custody copies, with access logged. Rotation requires decrypting and re-encrypting under a newly generated recipient, verifying the new ciphertext and manifest, and retaining the old identity until all artifacts encrypted to it expire and deletion is evidenced. If compromise is suspected, revoke access to the storage account, rotate the age recipient, re-encrypt retained backups, and document the incident. Never overwrite the only recoverable key.

## Production guard

No script in this package automatically exports production data. Encryption scripts accept an already-existing input file only. The existing exporter has a separate owner-approval marker and must not be invoked until every G3 authorization prerequisite is approved. This document is not production export authorization.
