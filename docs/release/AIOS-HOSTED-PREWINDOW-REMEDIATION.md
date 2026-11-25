# AiOS hosted pre-window remediation and migration plan

**Status:** PREPARATION ONLY. NOT AN EXECUTION AUTHORIZATION.  
**Project:** `jtkcdwhiduixoiodhbfn`  
**Region:** `eu-west-1`  
**Last fresh read-only snapshot:** 23 November 2026, 11:52 UTC  
**Production changes:** None.

## 1. Current baseline

- Hosted migration history: 117 applied through `20261108130000`.
- Candidate migration inventory: 131; 14 candidate migrations are unapplied.
- PostgreSQL: 17.6.
- Current inspection identity: `postgres`; `auth.uid()` is NULL. This cannot satisfy owner-authentication evidence.
- `aios_restorer` is absent.
- Four audit protection triggers are ORIGIN-enabled, not ALWAYS-enabled.
- `private.aios_audit_append()` has `search_path=""` but no UTC timezone pin.
- No mission-reconciliation schedule registry or cron job was found.
- Security Advisor: one private RLS-enabled/no-policy finding, three authenticated-executable SECURITY DEFINER RPC warnings, and leaked-password protection disabled.
- Succeeded missions and all three residual-live-child categories currently count zero. These are point-in-time observations only.

## 2. Unapplied migrations in timestamp order

| Order | Version | Migration | Primary change / risk |
|---:|---|---|---|
| 1 | 20261108140000 | `aios_execution_lock_order_and_task_terminal_cascade` | Mission/task/invocation/approval lock order and terminal cascade. Concurrency-sensitive. |
| 2 | 20261108150000 | `aios_approval_paths_global_lock_order` | Approval chain locking. Concurrency-sensitive. |
| 3 | 20261109120000 | `aios_restoration_part_d` | Creates guarded restoration state/role/functions; enables audit protections ALWAYS; revokes service-role audit mutation/trigger privileges. Privilege-sensitive. |
| 4 | 20261109130000 | `aios_audit_anchoring_part_e` | Anchors, canonical verifier, external attestation model. Audit-integrity-sensitive. |
| 5 | 20261110100000 | `aios_batch_prelock_before_audit` | Batch lock acquisition before audit writes. Concurrency-sensitive. |
| 6 | 20261111170000 | `aios_shared_approval_invocation_resolver` | Shared approval/invocation resolution and lock handling. Concurrency-sensitive. |
| 7 | 20261111190000 | `aios_restorer_allowlist_and_mission_reconciliation` | Restoration allowlist and mission reconciliation controls. Privilege/operations-sensitive. |
| 8 | 20261111200000 | `aios_mission_reconciliation_schedule_registry` | Schedule registry and reconciliation state. Operations-sensitive. |
| 9 | 20261111210000 | `aios_register_mission_reconciliation_trigger` | Registers mission reconciliation trigger. Trigger-sensitive. |
| 10 | 20261111220000 | `aios_approval_binding_and_audit_lock_order` | Approval binding revalidation and audit lock ordering. Concurrency/security-sensitive. |
| 11 | 20261111230000 | `aios_reaper_per_record_isolation` | Per-record reaper isolation. Concurrency-sensitive. |
| 12 | 20261113160000 | `aios_reaper_fail_closed_hardening` | Reaper fail-closed hardening. Operationally sensitive. |
| 13 | 20261120180000 | `aios_mission_cancellation_jwt_identity` | Caller-JWT identity-bound cancellation. Authorization-sensitive. |
| 14 | 20261120190000 | `aios_succeeded_mission_terminal_integrity` | Legacy succeeded-state boundary and closed task status contract. Data-precondition-sensitive. |

The timestamps establish migration order, not proof that the hosted environment is ready. Before a production window, compare the exact SQL files at the approved release SHA with the hosted catalog and verify the migration history again.

## 3. Mandatory pre-window evidence

Do not start a hosted migration until every item below is recorded and independently reviewed:

1. G1 exact-head workflows and artifacts pass on the exact release SHA.
2. G2 Agent 003 review accepts the exact release SHA and records no unresolved P1.
3. G3 production logical export, isolated restore, archive integrity, and recovery acceptance pass; provider-managed backup/PITR status is independently evidenced where applicable.
4. G4 fresh hosted parity is complete: migration history, schemas, constraints, indexes, triggers, trigger enablement, function definitions, owners, SECURITY DEFINER/search_path/timezone settings, grants, RLS and policies, roles/memberships, cron schedules, extensions, and relevant Auth settings.
5. Query and record succeeded missions and residual live tasks, invocations, and approvals immediately before the final migration. The last observed zero counts are not reusable as a release-time assertion.
6. Review all 14 migrations in timestamp order, including migration-specific preconditions and exact rollback/forward-recovery treatment.
7. Confirm a tested recovery route and a time-bounded maintenance window, operator, observer, communication channel, stop conditions, and post-window verifier.
8. Confirm owner-controlled branch rules, dependency PR integration order, and genuine owner authentication requirements.

## 4. Controlled migration sequence

This is a proposed sequence for a future approved window, not a command to run now.

**Phase A: freeze and capture**
- Freeze application writes and background workers as specified by an approved maintenance plan.
- Re-read migration history and all preflight counts.
- Capture and validate the approved production export and isolated restore.
- Record schema/function/grant/trigger/cron baselines and hashes.

**Phase B: dependency-ordered application**
- Apply only the reviewed migrations, in timestamp order, using the approved migration runner and a named operator.
- Stop immediately on any unexpected migration history, precondition failure, catalog drift, lock timeout, deadlock, or evidence mismatch.
- Do not manually mark migration versions applied and do not skip a failed migration.
- Do not grant application identities membership in `aios_restorer`; the Part D migration explicitly rejects unsafe membership/role state.

**Phase C: immediate verification**
- Verify all 131 expected migration versions are present.
- Verify all four audit protection triggers are ENABLE ALWAYS.
- Verify `service_role` has no UPDATE/DELETE/TRUNCATE/TRIGGER/REFERENCES on the audit table.
- Verify the restoration role is NOLOGIN/NOINHERIT and has no application/service membership.
- Verify canonical audit functions pin UTC and that anchor/verifier state is structurally consistent.
- Verify reconciliation registry, trigger and schedule are registered as intended.
- Verify function definitions, owners, grants, RLS/policies, cron schedules, and all candidate-vs-hosted fingerprints.
- Run the succeeded-child precondition and all documented read-only invariants.
- Run authenticated owner checks only from the actual owner's authenticated session. A postgres/service-role connection with NULL `auth.uid()` is not a substitute.

**Phase D: release decision**
- Agent 003 independently reviews the exact deployed SHA and post-window evidence.
- G6 remains open until all post-deployment checks pass.
- G7 is completed only by the Human Director directly.
- Any failed or ambiguous result keeps Release Hold active.

## 5. Stop and recovery rules

- Any migration error, unexpected row count, lock-order anomaly, role/grant mismatch, trigger fingerprint mismatch, audit-chain failure, missing anchor, schedule drift, or failed authenticated check is a hard stop.
- Never improvise DDL or privileges during the window.
- Never disable audit protections or widen role grants to get a migration through.
- Prefer the documented forward-recovery path when schema/data changes have committed; do not assume a reverse SQL migration is safe.
- If recovery is required, use the separately approved isolated restore process and record the exact source snapshot, target, operator, and validation result.

## 6. Current disposition

G4 remains **BLOCKED / NOT PASS**. This document is a remediation and execution-control plan only. No hosted migration, role/grant/RLS/trigger/cron/Auth change, production write, or deployment has been performed or authorized.
