# G3 Evidence Manifest

**Manifest status:** PREPARATION INVENTORY; not a production recovery manifest.  
**Feature branch:** `agent004/g3-zero-budget-recovery`  
**Base candidate:** `fe1fcbea1e9aba02689cb0bb48c0a1180e508504`

## Preparation artifacts

- `docs/recovery/G3-STORAGE-ASSESSMENT.md`
- `docs/recovery/G3-ENCRYPTION-AND-KEY-CUSTODY.md`
- `docs/recovery/G3-EXPORT-PROCEDURE.md`
- `docs/recovery/G3-RESTORE-PROCEDURE.md`
- `docs/recovery/G3-ISOLATED-RESTORE-PLAN.md`
- `docs/recovery/G3-TEST-RESULTS.md`
- `docs/recovery/G3-AUTHORIZATION-CHECKLIST.md`
- `docs/recovery/G3-EVIDENCE-MANIFEST.md`
- `docs/recovery/G3-AGENT-003-REVIEW-REQUEST.md`
- `scripts/recovery/encrypt_artifact.sh`
- `scripts/recovery/verify_manifest.sh`
- `scripts/recovery/decrypt_artifact.sh`
- `tests/recovery/test_crypto.sh`
- `.github/workflows/recovery-crypto.yml`

## Existing related artifacts (inherited from the parent candidate)

- `scripts/recovery/export_logical.sh`
- `scripts/recovery/restore_local.sh`
- `scripts/recovery/validate_local_restore.sh`
- `scripts/recovery/preflight_target_empty.sql`
- `tests/recovery/test_scripts.sh`
- `tests/recovery/postgres_roundtrip.sh`
- `tests/recovery/preflight_matrix.sh`
- `docs/operations/LOGICAL-EXPORT-RESTORE.md`
- `docs/release/AIOS-G3-EXPORT-AUTHORIZATION-PACK.md`

## Required execution evidence not yet present

- Owner's Drive ownership/quota/access/jurisdiction verification.
- Local device FileVault, free-space and PostgreSQL version inventory.
- Age production recipient/private identity custody record (never the private key itself).
- Synthetic Drive upload/download test performed by owner.
- Exact-head CI workflow URLs and logs for this branch.
- Production export ticket and authorization.
- Production ciphertext and independently held SHA-256 manifest.
- Verified isolated restore and application/security acceptance evidence.
- Agent 003 independent review disposition.

Do not place production artifacts, production manifests, credentials, key material or database contents in this repository. A code commit hash is not a backup digest.
