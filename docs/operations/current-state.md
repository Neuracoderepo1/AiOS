# AiOS current state and release boundary

**Snapshot:** 2026-11-13  
**Candidate inspected:** `13394941bc31a8005777ee40cf0ce87115e6783a`  
**Active review:** PR #35, draft and unmerged  
**Hosted project:** `jtkcdwhiduixoiodhbfn`, PostgreSQL 17.6, Supabase Free plan

## Current release status

Engineering source review for PR #35's F-2/P1 remediation is accepted by Agent 003. Production certification remains **WITHHELD**. No hosted migrations, production writes, deployment, merge, restore, plan upgrade, or billing change is authorized by this status document.

## Migration state

- Candidate tree: **128** unique, ordered SQL migration files.
- Hosted migration history: **117** applied; latest version `20261108130000`.
- Candidate migrations after the hosted watermark: **11 unapplied**. Exact versions and names are recorded in [the 2026-11-13 budget-neutral closure checkpoint](../release/2026-11-13-budget-neutral-closure.md).
- The AiOS CI migration job successfully replays the candidate migration tree from scratch on a disposable local Supabase/PostgreSQL stack. This proves clean-room replay in CI, not hosted schema parity.
- Do not apply the 11 missing migrations to the hosted project without a separately approved migration plan and release authorization.

## Hosted catalog observations

Read-only inspection on 2026-11-13 found:
- `aios_restorer` is absent from the hosted role catalog.
- Four audit-table protection triggers are enabled in ORIGIN mode, not ALWAYS mode.
- `service_role` retains UPDATE, DELETE, and TRIGGER privileges on `public.aios_audit_events`; it does not have TRUNCATE.
- Only the existing stale-task reaper and stale-approval expiry cron jobs are active.
- Public and private application tables inspected have RLS enabled. RLS is not FORCE-enabled on those tables.
- The connected SQL context is database role `postgres`, with no authenticated owner JWT context. It cannot prove owner-session audit verification.

These are observations, not authorization to repair hosted state. The candidate Part D migration explicitly hardens audit triggers and service-role grants; hosted parity remains a release blocker.

## GitHub governance observations

The GitHub branch metadata endpoint reports `main` as protected and lists required checks:
- `evidence-integrity`
- `functions-typecheck`
- `migrations-and-sql-tests`

The branch metadata reports enforcement for non-admins. The dedicated branch-protection endpoint returned HTTP 403 for the connected integration. The repository rulesets endpoint returned an empty list, which does not prove that inherited or organization-level rulesets are absent. Required reviews, CODEOWNERS enforcement, stale-review dismissal, force-push/deletion rules, and bypass actors remain incompletely verified. See the closure checkpoint for exact owner evidence required.

## Backup and recovery

The owner-supplied Supabase dashboard evidence and clarification establish that the current Free plan does not include scheduled daily backups or PITR. PITR requires the Pro plan plus a paid add-on. No managed backup, recoverable timestamp, successful restore test, or measured RPO/RTO has been evidenced.

A budget-neutral logical-export and isolated-restore workflow remains to be implemented and tested. Until that work is complete, recovery readiness is **NOT VERIFIED**. Do not represent a local synthetic test dump as a production backup.

## Governance

- Agent 004 implements and submits evidence.
- Agent 003 independently reviews and certifies.
- PRs #34 and #35 remain draft/unmerged pending their release gates.
- No production deployment, hosted migration, production write, plan change, restore, or merge is authorized by this document.
- Scope is AiOS only. Armadillon and Arbitron are excluded.

## Historical baseline note

The earlier baseline inventory in this document recorded 96 migration files and compared them with the then-current hosted history. That count is historical and must not be used as the current candidate inventory. The authoritative current count is 128 candidate files and 117 hosted-applied versions as of the snapshot above.
