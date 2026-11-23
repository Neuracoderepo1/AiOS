# G3 Production Export Authorization Checklist

**Status:** BLOCKED — mandatory owner-controlled prerequisites remain unresolved.  
**Source:** AiOS Supabase project `jtkcdwhiduixoiodhbfn`.

| # | Mandatory prerequisite | Current status | Required evidence |
|---:|---|---|---|
| 1 | Approved destination | BLOCKED | Explicit owner approval of exact destination |
| 2 | Owner-controlled storage account | BLOCKED | Owner verifies Drive account identity and control |
| 3 | Sufficient storage capacity | BLOCKED | Current quota and local free-space measurement |
| 4 | Encryption and key custody | PENDING | Age key generated and custody procedure accepted |
| 5 | Named authorized operator | BLOCKED | Named operator and role recorded |
| 6 | Authorization record / ticket | BLOCKED | Unique owner-approved ticket and scope |
| 7 | Secure transfer process | BLOCKED | Ciphertext-only upload/download test |
| 8 | Access-control register | BLOCKED | Named authorized readers and MFA/access review |
| 9 | Retention and deletion schedule | BLOCKED | Retention period, deletion date, evidence owner |
| 10 | Integrity-manifest custody | PENDING | Separate owner-controlled manifest copy and verifier |
| 11 | Isolated restore target | BLOCKED | Local/isolated target inventory and isolation evidence |
| 12 | Restore acceptance criteria | PENDING | Agent 003-approved criteria and validation evidence |
| 13 | Recovery Point Objective (RPO) | BLOCKED | Owner-approved target or explicit acknowledgement undefined |
| 14 | Recovery Time Objective (RTO) | BLOCKED | Owner-approved target or explicit acknowledgement undefined |

## Additional mandatory gates

- G2 exact-head engineering review accepted for the feature branch and its parent dependency.
- Export source/scope, point-in-time capture, database version and migration watermark identified.
- Destination jurisdiction and applicable data-residency questions resolved.
- Encryption key generated and private-key custody verified.
- Retention, deletion, sync/preview exposure and incident/rotation handling reviewed.
- Manifest independent verification and evidence custody agreed.
- Isolated restore operator, target, version, extensions and acceptance owner assigned.
- Human Director's explicit authorization for the exact production export operation recorded after all prerequisites pass.
- Agent 003 independently reviews the exact final preparation commit before export.

## Decision rule

A prerequisite marked BLOCKED or PENDING prevents production export. The technical exporter marker does not override this checklist. No standing delegation, chat acknowledgement or synthetic test substitutes for destination ownership, owner authentication, or exact operation approval.

**Current decision: production export is NOT AUTHORIZED. G3 is BLOCKED.**
