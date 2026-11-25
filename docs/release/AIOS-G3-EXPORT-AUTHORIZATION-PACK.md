# AiOS G3 production export and isolated-restore authorization record

**Status:** NOT APPROVED / NOT STARTED. Preparation template only.  
**Project:** `jtkcdwhiduixoiodhbfn` (Project AiOS, `eu-west-1`)  
**No production export has been initiated.**

**Plan constraint:** the AiOS organization is confirmed on Supabase Free. Supabase's [Database Backups documentation](https://supabase.com/docs/guides/platform/backups) states automatic daily backups are provided for Pro/Team/Enterprise; Free projects should maintain their own logical exports, and Free backups are not available for download. PITR is a paid add-on and is not assumed or enabled. G3 therefore requires a manually created logical export to an owner-approved encrypted off-platform destination.

This record must be completed and approved before any production logical export or transfer. Do not place passwords, private keys, access tokens, JWTs, connection strings, or recovery credentials in this document, GitHub, or chat.

## A. Source and scope

- Source project ID: `jtkcdwhiduixoiodhbfn`
- Source database: primary PostgreSQL database, exact database identity to be confirmed by the named operator immediately before execution.
- Export scope: full logical export required for the approved recovery objective, with separate schema-only inventory and extension/version inventory.
- Point-in-time source timestamp / transaction consistency marker: to be captured at execution.
- Named operator: **NOT ASSIGNED**
- Approval / change-ticket ID: **NOT ISSUED**

## B. Destination and custody

- Destination URI / storage location: **NOT APPROVED**
- Destination country / jurisdiction: **NOT APPROVED**
- Destination owner / custodian: **NOT ASSIGNED**
- Encryption at rest: **NOT CONFIRMED**
- Encryption in transit / transfer channel: **NOT APPROVED**
- Encryption key custodian and rotation/revocation procedure: **NOT ASSIGNED**
- Authorized readers: **NOT APPROVED**
- Integrity-manifest custodian: **NOT ASSIGNED**
- Retention period: **NOT APPROVED**
- Verified deletion date and deletion evidence owner: **NOT ASSIGNED**

The destination must be controlled by the project owner, encrypted, access-restricted, auditable, and separate from the production database. A temporary ChatGPT attachment or an unapproved repository artifact is not an acceptable production backup destination.

## C. Isolated restore target and acceptance

- Restore target identifier: **NOT PROVISIONED**
- Target isolation/network boundary: **NOT VERIFIED**
- Target operator: **NOT ASSIGNED**
- Restore method/version: documented `docs/operations/LOGICAL-EXPORT-RESTORE.md`, to be pinned at execution.
- Restore acceptance owner: **NOT ASSIGNED**
- Required validation: archive integrity; schema/object inventory; extensions; migration history; row-count and referential checks; audit-chain/anchor verification; trigger/function/grant/RLS parity; no production endpoints or outbound side effects.
- Acceptance result: **NOT RUN**

## D. Recovery objectives

- RPO: **NOT ESTABLISHED**
- RTO: **NOT ESTABLISHED**
- Owner acknowledgement of these unknowns: **PENDING**

## E. Execution checklist

- [ ] G2 exact-head engineering review accepted.
- [ ] Named operator and change ticket recorded.
- [ ] Source scope and point-in-time capture method approved.
- [ ] Destination, jurisdiction, encryption and key custody approved.
- [ ] Transfer channel and authorized access list approved.
- [ ] Retention/deletion date and evidence owner approved.
- [ ] Manifest custody and independent SHA-256 verification defined.
- [ ] Isolated restore target and operator approved.
- [ ] RPO/RTO recorded or explicitly acknowledged as not established.
- [ ] Export completed without exposing credentials or data in logs.
- [ ] Archive and manifest independently verified.
- [ ] Isolated restore completed and accepted.
- [ ] Agent 003 independently reviewed the evidence.

## F. Explicit non-authorization

Standing engineering delegation does not supply missing destination, custody, retention, recovery objective, or data-transfer decisions. No export, download, transfer, restore, or production data access beyond the recorded read-only catalog/count checks is authorized by this template. G3 remains **NOT STARTED** until the required owner-controlled fields and approvals exist.
