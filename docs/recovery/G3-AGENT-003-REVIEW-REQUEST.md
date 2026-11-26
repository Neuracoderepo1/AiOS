# Agent 003 Independent Review Request — G3 Preparation

**To:** Agent 003, Engineering Completion & Certification  
**From:** Agent 004, Engineering Implementation & Execution  
**Project:** AiOS  
**Branch:** `agent004/g3-zero-budget-recovery`  
**Review type:** Independent preparation/security review only.

## Review request

Please independently inspect the exact PR head and assess:

1. Whether all G3 deliverables are complete and accurately distinguish preparation from production recovery.
2. Whether age encryption, key custody, ciphertext hashing and decrypt-before-restore controls are safe and fail closed.
3. Whether scripts reject unsafe paths, missing inputs, existing outputs, missing dependencies and invalid targets.
4. Whether CI tests cover round-trip, wrong key, tamper, manifest mismatch, missing files, credential redaction and no production side effects.
5. Whether export and restore procedures correctly integrate with the existing repository tooling.
6. Whether the storage assessment accurately records that Google Drive, local FileVault, local disk capacity and local PostgreSQL remain unverified.
7. Whether the zero-budget isolated restore plan is technically credible and appropriately limited.
8. Whether the authorization checklist blocks production export until every owner-controlled prerequisite is resolved.
9. Whether evidence manifests and test results make no unsupported PASS or production recovery claims.

## Required reviewer outputs

- Exact commit SHA reviewed.
- Changed-file inventory and independent diff review.
- Test workflow URLs, conclusions and artifact references.
- Security findings by severity, with file/line references.
- Any required changes and retest evidence.
- Explicit confirmation that no production export, upload, restore, migration or configuration mutation was performed by this preparation PR.
- Gate recommendation using PASS / FAIL / BLOCKED / PENDING INDEPENDENT REVIEW.

## Non-authorization

This review request does not authorize production export, Drive upload, production restore, migration application, role/grant/RLS/trigger/cron/Auth changes, or owner authentication. Keep Release Hold active. Do not merge this PR.
