# Agent 003 handover: AiOS certification closure (prepared by Agent 004)

This is evidence for independent review, not a certification claim. Every item below states what was run and what was not.

Baseline: main d762f27 (verified against remote 2026-11-02), baseline run commit 292d398 present; original evidence checksums verified OK; `tests/matrix/manifest.json` unchanged since 292d398.
Implementation branch: `agent-004/aios-final-certification` (local; **not pushed, no PR, no CI run yet**).

| Area | Status | Evidence / note |
|---|---|---|
| Canonical matrix 46/46, G4 12/12 | PRESERVED (not re-run) | `docs/testing/evidence/`; `sha256sum -c SHA256SUMS` OK |
| Manifest + evidence integrity enforcement | IMPLEMENTED; local tests PASS (8/8); CI NOT RUN | `tests/integrity/`, `docs/testing/INTEGRITY.md`, pins `matrix-v1.pins` sha256 `e72d9171...5a95` |
| Org/task binding regression (07) | WRITTEN, UNRUN | `tests/sql/07_...sql` |
| Expiry audit/mixed batch/idempotency (08) | WRITTEN, UNRUN | `tests/sql/08_...sql` |
| Expiry concurrency | WRITTEN, UNRUN | `tests/concurrency/expiry_race.sh`, CI step added |
| Expiry repair in production | VERIFIED read-only 2026-11-02 | function structure matches repo `20261101232313` (marker comparison, not byte diff); cron */5 active; 0 stale pending; 1 pending, 22 expired; no disabled triggers; owner-decision retain record `8c47bb48-...` present |
| Cron health | EXCEPTION | 563 succeeded / 13 failed in last 24h; all failures job 2, 22:20-23:20 UTC Nov 1, cause invalid binding aborting batch; none after fix migration `20261101232313` |
| Migration parity | RECONCILED, no schema drift found | prod 111 / repo 110; prod-only `20261102062924/28/40`, `064034`; repo-only `090000/091000/100000` pair by name; live view, constraints, private RLS match repo; extra prod `...062940` folded into repo `...090000`. Version-number mismatch remains a documented exception; no migration was edited |
| RLS / grants / SECURITY DEFINER | REVIEWED | all tables RLS on; no SECURITY DEFINER without pinned path; anon denied; no client grants on private tables; 5 authenticated-executable definer functions reviewed (membership-checked) |
| Audit append-only | **GAP** | no TRUNCATE guard; service_role holds TRUNCATE; proposal 001 prepared, not applied |
| Audit-chain integrity | **NOT VERIFIED** | verifier is service-role only; no service-role access; procedure: run `public.verify_audit_chain(<org>)` server-side per org |
| Leaked-password protection | DISABLED (documented exception) | security advisor 2026-11-02 |
| Minor | view `service_role` has MAINTAIN | not revoked by repo migration; low risk |
| Release tag `matrix-v1.0` | NOT CREATED | absent on remote; target 292d398; maintainer command: `git tag -a matrix-v1.0 292d398d552625a32f784e68f3f00b48a8efb0a0 -m "<message>" && git push origin matrix-v1.0` |
| Production smoke-test suite | NOT STARTED | |
| Backup/recovery, monitoring/alerting review | NOT STARTED | |
| Production writes | NONE performed | all production access was read-only SELECT / advisor / migration list |

Reviewer instructions: fetch the branch (bundle or PR), run CI, then confirm the three UNRUN tests pass before relying on them; re-run the read-only production queries (migration list, trigger/grant catalog queries, cron.job_run_details) rather than trusting these figures; decide on proposal 001.
