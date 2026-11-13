# AiOS current state and release boundary

**Snapshot:** 2026-11-13  
**Candidate inspected:** `3a3fe839824f174b08607c8027f24672a18659e5`  
**Active review:** PR #35, draft and unmerged  
**Hosted project:** `jtkcdwhiduixoiodhbfn`, PostgreSQL 17.6, Supabase Free plan

## Current release status

Agent 003's source-review disposition for PR #35's F-2/P1 remediation remains accepted. Production certification remains **WITHHELD**. PR #35 and PR #34 remain unmerged. No hosted migrations, production writes, deployment, production export, restore, plan upgrade, billing change, or merge is authorized by this status document.

## Candidate and CI

The latest candidate adds the budget-neutral logical-export and isolated-restore scripts, safety self-tests, CI integration, and the recovery runbook. Its exact-head AiOS CI, ET27 delete-protection, and ET27 seal-guard runs are pending at the time of this snapshot. Do not reuse prior SHA workflow results as validation for this candidate.

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

The exporter requires explicit approval classification (loopback-only NONPRODUCTION or an owner approval ID for remote/production), uses PGPASSFILE, rejects remote host overrides for local restores, writes outside the repository, validates the archive, and produces SHA-256 checksums. The restore script refuses remote targets and requires an empty `aios_restore_*` database on loopback. The validator checks structural invariants and extension presence. Safety self-tests have been added to AiOS CI. Exact-head CI is pending. A successful real-PostgreSQL end-to-end export/restore exercise remains NOT VERIFIED. These scripts do not create a managed backup, PITR, automatic schedule, RPO, or RTO.

## Governance

- Agent 004 implements and submits evidence.
- Agent 003 independently reviews and certifies.
- PRs #34 and #35 remain draft/unmerged pending their release gates.
- No production deployment, hosted migration, production write/export, restore, plan change, or merge is authorized.
- Scope is AiOS only. Armadillon and Arbitron are excluded.

## Historical baseline note

Earlier inventory documents recorded a 96-migration baseline. That count is historical and must not be used as the current candidate inventory. The authoritative current count is 128 candidate files and 117 hosted-applied versions as of this snapshot.
