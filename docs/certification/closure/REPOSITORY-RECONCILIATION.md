# Repository Reconciliation — AiOS Final Production-Closure (Phase One)

Author: Agent 004 | Recorded: 2026-11-11 (UTC) | Status: PENDING REVIEW (Agent 003)
Method: REST API + `git fetch --depth=200` of each branch. No force-push, rebase, merge, or deploy performed.

## 1. Recorded heads

| Ref | PR | Base branch | Head SHA | Draft | GitHub mergeable |
|---|---|---|---|---|---|
| main | — | — | `bef031f2e084f9f327611dc5275c0ee56dfe0cb9` | — | — |
| closure/exec-authority-lock-order | #26 | main | `6f2cef9afc04a750510a7a17b62b85b5f1869b4b` | yes | clean |
| closure/approval-lock-order | #27 | closure/exec-authority-lock-order | `5565ea46ff7f00366300498c5a228772c599d80a` | yes | clean |
| fix/l3-audit-lock-order | #28 | **agent004/l3-evidence-hardening** | `e6c7b9a51ce8d6d4ff24fd4d7349cf874409cbe4` | yes | clean |
| feat/aios-restoration-audit-anchoring | #29 | main | `4275c70021bae9c65752916578c9f2cd3615200f` | yes | blocked (CI red) |
| agent004/l3-evidence-hardening | none | (stacked on #27 head) | `94729c4644e676a1f2f963dcd13c8cb4ce4e23fe` | no PR | — |

## 2. Actual dependency graph

```
main bef031f
 ├─ #26  6f2cef9                                   (1 commit)
 │    └─ #27  18d6ed5 → 061af7d → 5565ea4         (3 commits, stacked on #26)
 │          └─ agent004/l3-evidence-hardening      (+3 commits: 537cbf5, f36c9bb, 94729c4)  NO PR
 │                └─ #28  603b4a4 → e6c7b9a        (2 commits)
 └─ #29  4275c70                                   (1 commit, independent of #26-#28)
```

Findings:
1. **#28 is not independent.** Its base is an unreviewed, PR-less branch (`agent004/l3-evidence-hardening`) that itself stacks on #26 and #27. Merging #28 therefore carries #26, #27 and three evidence/CI-hardening commits that have no PR of their own. Those three commits (concurrency diagnostics, supabase-start infra retry, failure annotations) have never been reviewed as a unit.
2. **#29 is independent of the lock-order stack** at the commit level but shares file paths with #28 (below).
3. GitHub reports #28 "clean" only against its own base, not against `main`.

## 3. Migration dependency and ordering

| Timestamp | Migration | PR | Redefines |
|---|---|---|---|
| 20261108140000 | execution_lock_order_and_task_terminal_cascade | #26 | `aios_lock_execution_chain`, `aios_task_terminal_cascade`, `aios_mission_terminal_cascade` |
| 20261108150000 | approval_paths_global_lock_order | #27 | `aios_lock_approval_chain` (+ approval/expiry/reaper adoption) |
| 20261109120000 | restoration_part_d | #29 | restoration/guard functions, `aios_restorer` role |
| 20261109130000 | audit_anchoring_part_e | #29 | anchor/verify functions |
| 20261110100000 | batch_prelock_before_audit | #28 | `aios_lock_mission_subtree`, `aios_prelock_*_batch`, `aios_is_lock_conflict`, **`aios_expire_stale_approvals`, `aios_reap_stale_tasks`** |

- Timestamps interleave across PRs (#29's 1109xxx falls between #27's and #28's). Fresh replay order is valid in any merge order, but **no combined-stack replay (#26+#27+#28+#29) has ever been run**; every CI run tests a single branch.
- #28 re-`create or replace`s `aios_expire_stale_approvals` / `aios_reap_stale_tasks`, which #27 already modifies. Whoever merges second must be confirmed to supersede, not regress, the first. Golden function pins in #29 (`tests/golden/function_pins.tsv`) do not currently cover these two functions.

## 4. Outstanding conflicts (file-level, vs main)

| Path | Touched by | Risk |
|---|---|---|
| `.github/workflows/ci.yml` | #26, #27, #28 | #27/#28 inherit #26's edits; #29 does not modify ci.yml, so its new tests are **not wired into CI** |
| `.gitignore` | #28, #29 | textual conflict likely |
| `tests/harness/replay.sh` | #28 (add), #29 (add) | **add/add conflict** |
| `tests/harness/supabase_shim.sql` | #28 (add), #29 (add) | **add/add conflict** |
| `tests/harness/pg_jsonschema_stub.sql` | #28 (add), #29 (add) | **add/add conflict** |
| `docs/certification/closure/EXEC-AUTHORITY-RACES-2026-11-08.md` | #26, #27, #28 (same lineage) | none |

## 5. CI status per candidate commit

| Commit | Workflow runs | Result |
|---|---|---|
| 6f2cef9 (#26) | AiOS CI, ET27 seal guard, ET27 delete protection (pull_request) | all success |
| 5565ea4 (#27) | pull_request ×3 | success |
| 5565ea4 (#27) | **6× workflow_dispatch AiOS CI** | **3 failure, 3 success** — failing step in every failure: "Approval-path lock-order races" |
| 94729c4 (hardening) | 6× workflow_dispatch AiOS CI | 1 failure, 5 success (failing step: Approval-path lock-order races) |
| e6c7b9a (#28) | pull_request ×3 | all success (single run each) |
| 4275c70 (#29) | pull_request ×3 | **all failure** |

### 5.1 #27 / hardening branch: the race test is nondeterministic
The same SHA both passes and fails the "Approval-path lock-order races" step across dispatch runs. Either the product has a residual race or the test is not deterministic. This is **not** acceptable evidence either way, and the single green `pull_request` run on #27 and #28 must not be read as proof. Root cause is unexamined; it is carried into Phase Three as a blocking item.

### 5.2 #29: migration replay fails on the real Supabase local stack
Run 43001195667 (`migrations-and-sql-tests`), also seal-guard (43001195612) and delete-protection (43001195654), all stop at migration `20261109120000_aios_restoration_part_d.sql`:

```
ERROR: permission denied to alter role (SQLSTATE 42501)
Only roles with the SUPERUSER attribute may alter roles with the SUPERUSER attribute.
At statement: 1
alter role aios_restorer nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls
```

The migration runner on Supabase is not a superuser, and PostgreSQL requires superuser to ALTER any role's SUPERUSER attribute, even to `nosuperuser`. The PR's harness (plain PostgreSQL with a superuser and a Supabase shim) could not surface this, which is exactly the "harness-only" evidence gap the directive warns against. Consequently **all Part D / Part E claims are unverified on the target platform**, and the downstream steps (SQL suites, 46-case matrix, expiry regression, smoke self-test) were skipped in that run.

Note: `create role ... nosuperuser` at line 23 is guarded; only the unconditional `alter role` at line 26 fails. Fix design is deferred to Phase Five and will not weaken the "no ordinary role obtains restoration privileges" invariant.

## 6. Evidence-to-commit correspondence

- CI runs were matched to head SHAs via `actions/runs?head_sha=`. pull_request runs execute on the merge commit (e.g. run 43001195667 checked out `f172fdf`, the merge of 4275c70 into bef031f), not the branch head, so artifacts must record both SHAs. Existing artifacts have not yet been verified to do so.
- #29's own description labels it "NOT CI-verified"; the CI result above confirms that.
- No evidence exists for the four PRs combined.

## 7. Proposed integration sequence (for Human Director approval; nothing executed)

1. **Do not merge anything yet.** Resolve blockers first (below).
2. Open a PR (or explicitly designate) for `agent004/l3-evidence-hardening` so its 3 commits get review.
3. Fix #29 migration replay failure on its own branch; re-run CI on the Supabase stack.
4. Determine and fix the #27 race-test nondeterminism; require N consecutive green dispatch runs on the same SHA.
5. Create an **integration branch** from main (`closure/integration`) by merging, in order: #26 → #27 → hardening → #28 → #29, resolving the add/add harness conflicts in favor of a single reconciled `tests/harness/*`. Use merge commits; no rebase of shared branches.
6. Run the full combined migration replay, SQL suites, concurrency and mutation batteries, and CI on the integration head. Record the exact SHA.
7. Agent 003 reviews that exact SHA. Human Director decides on merge.

Integration-branch creation and pushes will happen only on a new branch, never on the five existing branches, unless authorized.

## 8. Blockers recorded by Phase One

| ID | Severity | Item |
|---|---|---|
| B-01 | High | #29 `alter role ... nosuperuser` fails on Supabase (42501); Part D/E unverified on target |
| B-02 | High | #27 lock-order race step is nondeterministic on the same SHA (3/6 red on 5565ea4) |
| B-03 | Medium | #28 depends on PR-less `agent004/l3-evidence-hardening` |
| B-04 | Medium | add/add conflicts between #28 and #29 in `tests/harness/` |
| B-05 | Medium | #29 tests not wired into CI; no combined-stack evidence |
| B-06 | Low | `aios_expire_stale_approvals`/`aios_reap_stale_tasks` not covered by golden pins |
