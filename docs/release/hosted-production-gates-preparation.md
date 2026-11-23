# AiOS hosted-production gates: preparation runbook

**Status: PREPARATION ONLY — NOT EXECUTED**  
**Authority:** Human Director's 22 November 2026 authorization for repository-only work packages 1–5 and procedure preparation for package 6.  
**Release hold:** ACTIVE.  
**Reference repository head at preparation:** f0f0b203e43166efa312ba9338b5ac59a113b3e1.  
**Target identifier for future authorized work:** Supabase project jtkcdwhiduixoiodhbfn. No connection to it was made under this authorization.

## 1. Execution control

This document is a checklist and procedure, not an execution record. No hosted database access, SQL, migration, export, restore, deployment, role/grant/RLS/trigger/cron/Auth/secret/configuration change, or production data operation is authorized by this document.

Every execution requires a separate written Human Director authorization naming:
1. the exact step or gate;
2. the target project/resource;
3. the environment (hosted production, disposable restore, or other);
4. the permitted operation and read/write boundary;
5. the expected evidence and stop conditions.

Silence, previous broad authority, CI success, repository access, and this runbook are not substitutes for that authorization. Agent 004 prepares and executes only within the specific authorization; Agent 003 independently reviews and certifies.

## 2. G10 — candidate-to-hosted fingerprint and parity method

### 2.1 Immutable candidate identity

Before a separately authorized read-only comparison:
- Freeze and record the exact repository commit SHA and branch.
- Record the Git tree SHA, migration inventory count, sorted migration filenames, and each migration blob SHA.
- Record tool versions and the canonicalization scripts/versions used.
- Produce a manifest containing relative path, byte length, SHA-256, and Git blob SHA for every relevant source file.
- Hash the manifest itself with SHA-256. Never include secret values, connection strings, JWTs, private keys, or credential-bearing environment output.

### 2.2 Database catalog fingerprint

If and only if a separate authorization permits read-only hosted catalog access, capture the following without changing state:
- PostgreSQL version, database identity label, schemas, relations, columns, types, defaults, constraints, indexes and ownership.
- Function/procedure identity arguments, language, volatility, security-definer flag, owner, normalized definition, proconfig including search_path/timezone pins, and EXECUTE grants.
- Table/sequence grants, default privileges, role attributes and role memberships; do not export password hashes or secret material.
- RLS enable/force flags, policies, trigger definitions and enablement mode.
- Extension inventory and versions.
- Migration ledger versions and timestamps.
- Cron job IDs, names, schedules, commands and active state. Redact any command fragments that could contain secrets.
- Auth and Edge Function configuration as presence/name/version metadata only unless a separately authorized scope explicitly permits more.

Canonicalize each object class deterministically: stable ordering by schema/name/signature, UTF-8, LF line endings, normalized whitespace only where semantics are unchanged, and explicit NULL/boolean representation. Do not normalize away security-significant attributes. Produce one SHA-256 per object class and a top-level manifest hash. Retain raw restricted captures separately with access controls; publish only redacted summaries and digests.

### 2.3 Comparison and acceptance

Compare the authorized hosted snapshot with a clean disposable replay of the exact candidate SHA. Report each difference as:
- expected candidate-only change;
- expected hosted-only legacy state;
- unexplained drift;
- unavailable/not observed.

A matching aggregate hash is not sufficient by itself: retain object-level diff records for grants, function definitions, RLS, triggers, cron and migration history. No parity claim is made until every required class is present and reviewed. A missing capture is NOT VERIFIED, never PASS.

## 3. G11 — staged migration preparation

The candidate record lists 14 unapplied migration versions against a historical hosted observation of 117 applied versions through 20261108130000. That is a historical comparison, not a current hosted assertion. Reconfirm only under a separately authorized read-only gate immediately before any migration authorization.

The proposed order is strict ascending migration version. This is a proposed sequence, not permission to apply any migration.

| Order | Version | Migration purpose | Required precondition / validation focus |
|---:|---|---|---|
| 1 | 20261108140000 | Execution lock order and task terminal cascade | Review mission/task lock ordering, terminal-state behavior, cascade effects and deadlock tests |
| 2 | 20261108150000 | Approval paths global lock order | Confirm resolver/approval lock-order dependencies and concurrency regression coverage |
| 3 | 20261109120000 | Restoration Part D | Confirm role-provisioning fail-closed checks, owner-only restoration boundary and catalog drift guards |
| 4 | 20261109130000 | Audit anchoring Part E | Confirm Part D prerequisites, audit-chain invariants, append-only behavior and verifier grants |
| 5 | 20261110100000 | Batch prelock before audit | Confirm audit advisory-lock ordering and batch/record lock interleaving tests |
| 6 | 20261111170000 | Shared approval/invocation resolver | Confirm caller authority and deterministic resolver ordering |
| 7 | 20261111190000 | Restorer allowlist and mission reconciliation | Confirm Part D role assumptions and reconciliation fail-closed behavior |
| 8 | 20261111200000 | Mission reconciliation schedule registry | Confirm registry uniqueness, schedule ownership and no duplicate active jobs |
| 9 | 20261111210000 | Register mission reconciliation trigger | Confirm registry contract and trigger idempotency |
| 10 | 20261111220000 | Approval binding and audit lock order | Confirm shared resolver integration, UTC audit writer behavior and forced lock interleavings |
| 11 | 20261111230000 | Stale-task reaper per-record isolation | Confirm per-record failure isolation and cross-organization lock-order tests |
| 12 | 20261113160000 | Stale-task reaper fail-closed hardening | Confirm schedule wrapper, stale-task semantics and failure-path tests |
| 13 | 20261120180000 | Mission cancellation JWT identity | Confirm caller identity derives from authenticated JWT and no caller-supplied actor identity is trusted |
| 14 | 20261120190000 | Succeeded-mission terminal integrity | Confirm trusted legacy-seed exception, closed task-status set and terminal-parent invariant |

### 3.1 Per-migration execution card (to be completed only after authorization)

For each migration, record:
- exact version, filename, source blob SHA and parent candidate SHA;
- prerequisite versions and dependency review;
- pre-migration ledger and relevant object fingerprints;
- precondition query outputs, with no sensitive values;
- approved execution identity and exact environment;
- start/end timestamps and command/tool version;
- transaction/runner outcome and any error;
- post-migration ledger version, object-level diffs and regression results;
- recovery decision and Human Director notification.

Stop immediately on any unexpected result. Do not skip a failed migration and continue with later versions. Do not manually reproduce migration effects through ad-hoc SQL.

## 4. G12 — parity checklist

Before a future migration window, a separately authorized review must establish:
- [ ] Exact candidate SHA frozen and independently recorded.
- [ ] Candidate migration count and ordered filenames verified.
- [ ] Hosted migration ledger freshly captured; no reliance on the historical 117-version observation.
- [ ] All 14 candidate-only versions reconciled against the hosted ledger.
- [ ] Table/column/constraint/index/sequence parity reviewed.
- [ ] Function body, owner, security-definer, search_path/timezone and EXECUTE-grant parity reviewed.
- [ ] Role attributes, memberships, table grants and default privileges reviewed.
- [ ] RLS flags, policy definitions and trigger definitions/enablement reviewed.
- [ ] Cron registry and command parity reviewed.
- [ ] Edge Function source/deployment version and configuration-presence inventory reviewed.
- [ ] Auth configuration and relevant project settings reviewed within the authorized read boundary.
- [ ] Every unexplained delta has an owner, severity and disposition.
- [ ] Agent 003 has reviewed the evidence where required.
- [ ] Human Director has separately authorized the specific execution step.

Missing evidence means NOT VERIFIED and blocks the next step.

## 5. G13 — backup and isolated restore preparation

The currently recorded plan is budget-neutral; no paid plan change is authorized. Supabase Free has no managed scheduled backup/PITR capability in the recorded project context. Do not imply managed recovery coverage.

Proposed procedure, only after separate authorization:
1. Confirm the exact source project and approved read/export scope.
2. Record the source migration ledger and pre-export catalog/data fingerprints.
3. Produce a schema-and-data logical dump using an approved, version-pinned toolchain.
4. Ensure credentials are supplied through a protected mechanism, never command-line arguments, logs, shell history or artifact contents.
5. Encrypt the dump at rest, restrict access, and calculate SHA-256 over the exact archive bytes.
6. Restore only into a disposable isolated environment with outbound access constrained and no production credentials.
7. Verify restore completion, schema/object fingerprints, selected row counts and referential/invariant checks.
8. Record elapsed export, restore and validation times; calculate measured RTO. Record RPO limitations honestly: a one-time dump does not provide continuous recovery or a guaranteed recovery point.
9. Retain the evidence manifest and sanitized logs. Destroy disposable resources only after evidence verification and according to the approved retention plan.

Acceptance requires byte-level dump integrity plus semantic restore checks. A successful CI roundtrip is not a substitute for an authorized production-source dump and isolated restore. Do not call this a production recovery exercise until the exact source/restore exercise has been performed and reviewed.

## 6. G14 — authenticated owner-session verification procedure

This procedure requires a separate Human Director authorization and a genuine interactive owner session:
1. The Human Director signs in through the normal application authentication flow using the intended owner account.
2. Capture the actual session subject from the authenticated identity context. Do not substitute service_role, a database superuser, a fabricated JWT, or a caller-supplied actor UUID.
3. Confirm the target organization using the authenticated user's actual membership and record the organization identifier in the restricted evidence record.
4. Invoke only the approved owner-verification path through its intended authenticated interface.
5. Verify that the result is scoped to the authorized organization and that the audit record attributes the action to the authenticated subject.
6. Capture request/result timestamps, HTTP/database outcome, sanitized response, and evidence hashes. Do not capture or publish the bearer token, refresh token, cookie, password, or secret.
7. Have Agent 003 independently inspect the sanitized evidence and verify identity binding, owner authorization, tenant scoping and audit attribution.

A service-role or simulated-owner test is not an owner-session proof. If the real owner session cannot be established, mark the gate NOT VERIFIED.

## 7. G15 — rollback and recovery decision plan

The candidate migration series has no down-migrations. Therefore the plan is forward-fix or restoration from the separately verified pre-migration dump; it is not reverse SQL.

Before any future execution:
- Confirm the dump and isolated restore passed, the dump digest is recorded, and the restore location is available.
- Confirm the exact stop/rollback decision owner and communication path.
- Confirm no later migration will run automatically after a failed step.
- Define the forward-fix review and approval path; no ad-hoc production patching.
- Define restoration prerequisites, acceptable data-loss window, application maintenance state and post-restore verification.
- Confirm that the recovery procedure does not require unapproved paid services or credentials.

On any failure:
1. Stop the sequence immediately and preserve sanitized logs.
2. Do not rerun blindly, skip the failed version, or apply subsequent migrations.
3. Record the exact migration, commit, environment, error and observed partial effects.
4. Notify the Human Director and request a separate written recovery decision.
5. Execute only the explicitly authorized forward-fix or restoration step.
6. Re-run the approved parity and smoke checks before declaring the environment stable.

No rollback, restore, forward-fix or production recovery action is authorized by this preparation document.

## 8. Explicit non-execution record

At authoring time, this file records ZERO hosted operations. No hosted connection was opened, no hosted query was run, no migration was applied, no export/restore was initiated, no deployment occurred, and no production setting or privilege was changed. All gates described above remain PREPARED / NOT EXECUTED / NOT PASSED pending separate step-specific authorization.
