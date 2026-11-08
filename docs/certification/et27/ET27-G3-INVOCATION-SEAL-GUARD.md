# ET27 / G3: invocation seal guard certification report

Decision: **CONDITIONAL PASS.** The guard works and no tested invariant was bypassable; conditions are listed under "Limitations".

- Branch: `feat/et27-g3-invocation-seal-guard` (draft PR #22, not merged, **not applied to production**)
- Code verified at commit `b0dc65a4530cc65a8d2d8c23ecfcda802fd4d2ef`
- CI evidence, same commit: AiOS CI run 42479692042 (success), ET27 seal guard evidence run 42479692136 (success)
- Earlier green run on `4209bc1`: AiOS CI run 42479469905

## What was built
- `supabase/migrations/20261108120000_aios_invocation_seal_guard.sql`: `private.aios_invocation_seal_guard()` as a BEFORE UPDATE trigger with no
  column list. Frozen from `executing`: identity, tool, arguments, hashes, approval and authorization evidence, provenance, risk, started/evaluated.
  Frozen once terminal (succeeded, failed, denied, cancelled, expired): every column except `retry_count`. `id` and `created_at` are always frozen.
  The guard compares whole rows against a MUTABLE allowlist, so a column added later is sealed by default.
  Also blocks TRUNCATE of the invocation ledger (trigger + revoked privilege).
- `tests/sql/10_invocation_seal_guard.sql`: real-database adversarial, coverage, privilege and in-database mutation tests.
- `.github/workflows/et27-seal-guard-evidence.yml`: additive evidence workflow; the pinned `ci.yml` is untouched.

## Results (from CI annotations)
- Migration replay: 116 migration files applied on a fresh database by `supabase start`.
- Seal guard suite: **303 checks, 0 failed** (351 result rows incl. 48 mutant verdicts; 0 FAIL). psql exit code 0.
- Mutation testing: **48 mutants, 48 detected, 0 survived.** 21 terminal-column un-freezes, 15 executing-column un-freezes,
  5 branch/comparison removals, 5 terminal-state-set removals, and 3 trigger mutations (dropped, narrowed to `UPDATE OF status,result`, disabled).
- Schema coverage: all 24 live columns classified; a new unclassified column fails COV1.
- Existing suites on the branch, all success: evidence integrity + 7 mutation cases, Edge Function O1-O6 + type-check, every `tests/sql` file,
  canonical matrix (46 cases), expiry concurrency regression, smoke self-test. No existing test or assertion was modified.

## Test design notes
- Attacks run as `service_role` with a service-role JWT through the real triggers. Each column is attacked in each terminal state and in `executing`.
- Every check runs in two modes: all triggers on, and "isolated" (other BEFORE UPDATE triggers disabled) so the seal guard alone must stop it.
  Mutants are only judged in isolated mode, which proves protection comes from this guard and not from an older trigger.
- Executing to denied is not a supported transition (denial happens before execution); the suite asserts it is rejected.

## Limitations (reasons for CONDITIONAL)
1. Not deployed. Production `jtkcdwhiduixoiodhbfn` has no seal guard and still lets service_role rewrite terminal outcomes until the migration is applied.
2. `retry_count` stays mutable on sealed rows (operational counter, not an outcome).
3. Pre-execution rows (requested through approved) are sealed by this guard only for `id` and `created_at`; their other columns rely on existing triggers, which were not mutation-tested here.
4. DELETE protection is indirect: deleting an audited invocation fails on the deferred FK from `aios_audit_events`, and audit rows are immutable. There is no explicit DELETE trigger, and `service_role` still holds DELETE.
5. A table owner or superuser can disable or drop the trigger; the suite proves it is present and enabled in CI, not at runtime. A post-deploy smoke check is recommended.
6. Mutation testing is function-level (guard rewrites in-database), not source-level mutation of the whole kernel.
7. Raw CI logs were not retrievable from the authoring environment (blob host blocked); counts above come from annotations the workflow wrote. The artifact `et27-seal-guard-evidence` holds the raw output (90-day retention).
