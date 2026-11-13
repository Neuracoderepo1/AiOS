# AiOS current state and release boundary

**Snapshot:** 2026-11-13  
**Last independently reviewed implementation candidate:** `40f80035e43e12604ad326388772008017171dbf`  
**Current PR #35 follow-up:** restore-preflight atomicity test and documentation reconciliation; exact successor SHA is the current PR head and requires fresh CI.  
**Active review:** PR #35, draft and unmerged  
**Hosted project:** `jtkcdwhiduixoiodhbfn`, PostgreSQL 17.6, Supabase Free plan

## Current release status

Agent 003's source-review disposition for PR #35's F-2/P1 remediation remains accepted. Production certification remains **WITHHELD**. PR #35 and PR #34 remain unmerged. No hosted migrations, production writes, deployment, production export, restore, plan upgrade, billing change, or merge is authorized by this status document.

## Candidate and CI

The reviewed implementation baseline `40f80035e43e12604ad326388772008017171dbf` passed all three exact-head workflows: AiOS CI `43404925437`, ET27 delete protection `43404925475`, and ET27 seal guard `43404925438`. Its four evidence artifacts were independently hashed and matched GitHub metadata. The current follow-up adds an explicit, read-only, enumerated restore-target preflight contract and a real-PostgreSQL regression that deliberately bypasses only the preflight to prove `pg_restore --single-transaction --exit-on-error` rolls back earlier archive objects after a later duplicate-relation conflict. This follow-up also reconciles the stale release records. These successor changes require fresh exact-head CI; the baseline's green runs do not certify the successor.

## Restore preflight contract

The restore preflight is intentionally scoped and documented rather than claiming to enumerate every PostgreSQL catalog object. It checks non-system schemas (except the standard `public` schema itself), every public relation kind, routines, user-defined types, collations, conversions, operators, operator classes/families, text-search objects, and extended statistics, excluding extension-owned objects. The runbook explicitly lists non-enumerated database-level classes. Any restore-time collision or error is handled by `pg_restore --exit-on-error --single-transaction`; the added disposable PostgreSQL regression confirms an earlier archive-created schema and extension are rolled back and the pre-existing conflicting table remains unchanged. The restore path never drops target objects.

## Migration state

- Candidate tree: **128** unique, ordered SQL migration files.
- Hosted migration history: **117** applied; latest version `20261108130000`.
- Candidate migrations after the hosted watermark: **11 unapplied**. Exact versions and names are recorded in [the budget-neutral closure checkpoint](../release/2026-11-13-budget-neutral-closure.md).
- AiOS CI clean-room replay applies the candidate migration tree to a disposable local Supabase/PostgreSQL stack. This proves replay from scratch in CI, not hosted schema parity.
- Do not apply the 11 missing migrations to the hosted project without a separately approved migration plan and release authorization.

## Hosted catalog observations

Read-only catalog inspection on 2026-11-13 found:
- PostgreSQL 17.6; `current_user = session_user = postgres`; `auth.uid()` is NULL in the connected SQL session.
- 70 application functions in public/private schemas, including 48 SECURITY DEFINER functions. All inspected SECURITY DEFINER functions are owned by postgres, use `search_path = ''`, and have no PUBLIC or anon EXECUTE privilege. Five SECURITY DEFINER functions are executable by authenticated and 14 by service_role; these grants require function-by-function intent review, not blanket revocation.
- 18 application tables inspected, all with RLS enabled; none have FORCE RLS. 38 policies exist across public/private schemas.
- `aios_restorer` is absent from the hosted role catalog.
- Four audit protection triggers on `public.aios_audit_events` are ORIGIN-enabled, not ALWAYS-enabled. Two additional organization-validation triggers are also ORIGIN-enabled.
- `service_role` retains SELECT, INSERT, UPDATE, DELETE, REFERENCES, and TRIGGER privileges on `public.aios_audit_events`; it does not have TRUNCATE. The candidate Part D migration narrows these grants.
- Seven extensions are installed: pg_cron 1.6.4, pg_jsonschema 0.3.3, pg_stat_statements 1.11, pgcrypto 1.3, plpgsql 1.0, supabase_vault 0.3.1, and uuid-ossp 1.1.
- Only two active cron jobs are present: stale-task reaper and stale-approval expiry, both every five minutes.
- The owner-context audit-chain verifier cannot be certified through this connection because there is no authenticated owner JWT context.

These are hosted observations, not authorization to repair hosted state. Full function-definition/hash parity against the candidate's replayed migration state remains incomplete. See the closure checkpoint for the findings register and required owner evidence.

## GitHub governance observations

Read-only GitHub branch metadata reports `main` as protected with required checks:
- `evidence-integrity`
- `functions-typecheck`
- `migrations-and-sql-tests`

The branch metadata reports enforcement for non-admins. The dedicated branch-protection endpoint returned HTTP 403 for the connected integration. The repository rulesets endpoint returned an empty list, which does not prove inherited or organization-level rulesets are absent. Required reviews, CODEOWNERS enforcement, stale-review dismissal, force-push/deletion rules, and bypass actors remain incompletely verified.

## Backup and recovery

The owner-supplied dashboard evidence and clarification establish that Supabase Free does not include scheduled project backups. Daily backups are included with Pro; PITR requires Pro plus a paid add-on. No managed backup timestamp, recoverable range, production export, successful restore test, or measured RPO/RTO has been evidenced.

Budget-neutral scripts now exist:
- `scripts/recovery/export_logical.sh`
- `scripts/recovery/restore_local.sh`
- `scripts/recovery/validate_local_restore.sh`
- `tests/recovery/test_scripts.sh`
- `docs/operations/LOGICAL-EXPORT-RESTORE.md`

The exporter requires explicit approval classification (loopback-only NONPRODUCTION or an owner approval ID for remote/production), uses PGPASSFILE, rejects remote host overrides for local restores, writes outside the repository, validates the archive, and produces SHA-256 checksums. The restore script refuses remote targets and requires an `aios_restore_*` database on loopback containing no pre-existing user schemas or objects. The emptiness guard covers all relation kinds (including partitioned tables), routines, and user-defined types in public, and rejects non-system custom schemas. Negative PostgreSQL tests verify that custom schemas and partitioned tables are rejected without being modified. The validator checks structural invariants and extension presence. Safety self-tests have been added to AiOS CI. The synthetic real-PostgreSQL export/restore roundtrip passed on the prior reviewed head. The new negative tests for pre-existing custom schemas and partitioned tables are added in the current follow-up and require fresh exact-head CI. It verified checksums, schema/data restore, RLS, four audit-event triggers, verifier-function presence, extension presence, and matching 3+2 source/restored fixture rows. This does not prove a full hosted AiOS restore or production recovery readiness. These scripts do not create a managed backup, PITR, automatic schedule, RPO, or RTO.

## Governance

- Agent 004 implements and submits evidence.
- Agent 003 independently reviews and certifies.
- PRs #34 and #35 remain draft/unmerged pending their release gates. The follow-up implementation is on the existing PR #35 head branch `agent004/f2-reaper-record-isolation`, based on reviewed head `0bf79e798f01b77ad665fc1e71873b29c104e5b7`.
- No production deployment, hosted migration, production write/export, restore, plan change, or merge is authorized.
- Scope is AiOS only. Armadillon and Arbitron are excluded.

## Historical baseline note

Earlier inventory documents recorded a 96-migration baseline. That count is historical and must not be used as the current candidate inventory. The authoritative current count is 128 candidate files and 117 hosted-applied versions as of this snapshot.
