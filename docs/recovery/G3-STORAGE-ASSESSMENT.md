# G3 Storage Assessment

**Assessment date:** 2026-11-23  
**Project:** AiOS / Supabase project `jtkcdwhiduixoiodhbfn`  
**Status:** BLOCKED — owner designation/attestation is recorded, but operational storage and transfer controls remain unverified.

## Executive finding

The Human Director designated a specific Google Drive folder and attested in the PR #43 record that it is owner-controlled and authorized for AiOS recovery evidence. This establishes the owner's stated destination choice and permission. It does **not** establish that the connected execution environment can access the folder, that quota is sufficient, that sharing/access controls are correct, that jurisdiction and retention are acceptable, or that encrypted upload/download has been tested.

Google Drive remains **owner-designated but not operationally approved**. No production export or upload has been performed.

## Evidence and limits

| Control | Finding | Status |
|---|---|---|
| Destination selection | Exact Drive folder designated by Human Director | OWNER DESIGNATED |
| Owner control / intended use | Human Director attestation recorded in PR #43 conversation | OWNER ATTESTED |
| Authenticated Drive access | No connected Google Drive account or authenticated Drive browser session available to this execution environment; Google Drive plugin is disabled by administrator | BLOCKED |
| Available Drive capacity | Not visible without owner-authenticated Drive access | BLOCKED |
| Drive sharing/access restrictions | Public-link state and collaborator list not inspected | BLOCKED |
| Encrypted-before-upload workflow | Age tooling prepared; destination workflow not exercised | PENDING |
| Download-and-verify workflow | Script prepared; Drive round trip not exercised | PENDING |
| Local OS / free disk capacity | Agent has no access to Human Director's Mac or its filesystem | BLOCKED |
| FileVault | Cannot query local macOS security state remotely | BLOCKED |
| Local PostgreSQL installation | Not verified on Human Director's device | BLOCKED |
| Data residency / jurisdiction | Account region, service terms and applicable account settings not inspected | BLOCKED |
| Retention/deletion | No owner-approved schedule or deletion evidence process recorded | BLOCKED |
| Named operator / access register | Not yet recorded | BLOCKED |

## Security assessment

1. Do not assume Google Drive's provider-side encryption substitutes for client-side encryption. Only the encrypted `.age` artifact may be uploaded.
2. Do not enable public or "anyone with the link" sharing. Restrict access to named owner-controlled identities.
3. Verify account recovery options and multi-factor authentication directly in the owner account. Do not share recovery codes or credentials in chat.
4. Verify jurisdiction and data residency against the account's actual terms and settings before production data is placed there.
5. Define retention, deletion, trash/bin handling, synchronized-device copies and deletion evidence before production export.
6. A public GitHub repository is not a backup destination. No export, sensitive manifest, key, or identity file may be committed.
7. The age identity/private key must remain outside Drive alongside the encrypted artifact. Store the private identity in owner-controlled offline custody; never upload it beside the artifact.

## Zero-budget alternatives

The first choice remains the Human Director's designated Google Drive folder, subject to owner-side verification. If it cannot meet the controls, do not silently switch destinations. No external SSD is assumed available. A second owner-controlled computer or already-owned encrypted storage may be assessed only with explicit owner approval and a verified isolation/access plan. A local-only copy is not off-site recovery and is not an acceptable substitute for the approved destination.

## Required owner-side evidence

- Signed-in account identity and available storage quota, with email address and personal data redacted from repository evidence.
- Drive sharing settings and authorized-reader register.
- Account MFA/recovery readiness confirmation, without recovery codes.
- Country/jurisdiction and retention decision.
- Confirmation that sync/preview/sharing will expose only ciphertext.
- Synthetic ciphertext upload, download, SHA-256 verification and decryption round trip performed by the owner before production use.
- Named operator and secure transfer procedure.

**Conclusion:** Google Drive is owner-designated and owner-attested, but not operationally verified or approved for production recovery. G3 production export remains BLOCKED.
