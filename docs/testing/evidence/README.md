# Canonical test matrix evidence: CI run 41404721275

| Item | Value |
|---|---|
| Repository | `Neuracoderepo1/AiOS` |
| CI run | `41404721275` (`AiOS CI`, attempt 1, conclusion `success`) |
| Tested commit | `292d398d552625a32f784e68f3f00b48a8efb0a0` (branch `fix/convergence-invalid-binding-isolation`) |
| Matrix job | `125144042093` (`migrations-and-sql-tests`, step 7 "Canonical test matrix (46 cases)") |
| Lost artifact | `13123335566` (`aios-ci-evidence`) |

## Why this evidence was reconstructed

The GitHub artifact download for artifact `13123335566` failed with an HTTP/blob-storage error and returned a zero-byte ZIP.
That artifact was **not used**. The evidence below was **reconstructed from the GitHub Actions job logs** of the original run
(not a re-run). The job logs were retrieved through the Actions API endpoints `GET /actions/jobs/{id}/logs`,
`GET /actions/runs/{id}` and `GET /actions/runs/{id}/jobs`.

Transport detail (for full transparency): the environment used for analysis cannot resolve GitHub's log-storage hosts, so a
one-shot workflow (`fetch-ci-evidence`, since removed from the tree) ran on GitHub runners, downloaded the original
logs with the Actions API, and committed them unmodified (commit `96c6b26`, authored by `github-actions[bot]`; the first
attempt, workflow run `41406171656`, hashed the logs but `.gitignore` (`*.log`) kept them out of the commit, and the second attempt,
workflow run `41406240181`, force-added them). The runner-side SHA-256 values (`raw-transport.sha256`) were re-checked locally after
checkout and all four files matched.

## Layout

- `raw/` : byte-exact originals. Job logs for both jobs, plus run and jobs metadata JSON. **Never edited.**
- `raw-transport.sha256` : hashes computed on the runner at download time.
- `extracted/` : derived slices of `raw/job-125144042093.log` (timestamps stripped; line content otherwise verbatim).
  - `matrix-run.txt` : the complete output of `tests/matrix/run.sh` from the log
  - `mx_results.txt` : every `MX_RESULT` record (45)
  - `g4.log` : the complete G4 eight-way concurrency output
  - `ci-verifier-output.txt` : the verifier output CI itself printed
  - `verify-reproduced.txt`, `report.reproduced.json` : output of re-running `tests/matrix/verify.py` (from commit `292d398`) over the extracted slices
  - `summary.json` : machine-readable summary
- `reproduce/reconstruct_matrix_evidence.py` : the extraction/verification tool
- `SHA256SUMS` : SHA-256 of every file in this directory (except itself)

## Results

| Domain | Passed | Expected |
|---|---|---|
| Authentication and identity | 5 | 5 |
| Organization isolation | 6 | 6 |
| Agent registry and trust | 5 | 5 |
| Tool registry and contracts | 5 | 5 |
| Risk and budget controls | 5 | 5 |
| Approval lifecycle | 7 | 7 |
| Execution and idempotency (4 SQL + G4) | 5 | 5 |
| Audit and persistence | 4 | 4 |
| Security and permissions | 4 | 4 |
| **Total** | **46** | **46** |

- 45 SQL cases: 45 unique `MX_RESULT` records, all `PASS`, matching `tests/matrix/manifest.json` exactly (none missing, extra, duplicated or moved).
- G4: 12 of 12 ordered checks `PASS` plus the `ok: G4 eight-way concurrency` marker. G4 does not emit an `MX_RESULT` line by design, so none is
  present and none has been added; it is evidenced by its 12 `PASS` lines in `extracted/g4.log`.
- The verifier output reproduced locally is identical to the verifier output printed by CI in the original log.
- Raw matrix job log: 41,923 bytes, SHA-256 `fc666afc4c4f3084c0cf7cc6d035a9371f2c314125832c013ed457f4f6682b79`.

## What this evidence does not contain

- The original artifact files (`environment.txt`, full `sql-05.log`, `report.json`, `matrix-run.txt` as uploaded). `run.sh` pipes `MX_RESULT` lines
  through `cut -c1-240`; zero of the 45 records reached that limit, so no detail text was shortened.
- The job log also contains `MX_RESULT` lines from the earlier generic "SQL regression and invariant tests" step (90 in total); only the
  45 inside the `tests/matrix/run.sh` section are counted as matrix evidence.
- No record was altered, inferred or created. Timestamps were removed only in `extracted/`; `raw/` retains them.

## Reproduce independently

1. Fetch the original job log with a token that has Actions: Read:
   `curl -L -H "Authorization: Bearer $PAT" https://api.github.com/repos/Neuracoderepo1/AiOS/actions/jobs/125144042093/logs -o job.log`
   and compare `sha256sum job.log` with the value above (GitHub may expire logs after its retention period; `raw/` preserves them).
2. `git show 292d398:tests/matrix/verify.py > verify.py; git show 292d398:tests/matrix/manifest.json > manifest.json`
3. `python3 reproduce/reconstruct_matrix_evidence.py --raw job.log --verify verify.py --manifest manifest.json --out /tmp/out`
   Expect `ok: true`, 46 passed, `reproduced_equals_ci_verifier_output: true`.
4. Strongest check, independent of GitHub: check out `292d398`, build a fresh database from `supabase/migrations` only, and run
   `bash tests/matrix/run.sh <DB_URL>` (needs psql, bash, bc, python3; G4 commits fixtures, so use a fresh database).
