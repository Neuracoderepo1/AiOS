# Certification evidence integrity

**What is enforced.** `tests/integrity/verify_integrity.py` compares every file under `docs/testing/evidence/` plus
`tests/matrix/manifest.json` against `tests/integrity/pins/matrix-v1.pins` (path set and SHA-256, exact match).
Modified, missing, added or renamed files fail. The pin file itself is anchored by a second, independent value
(`ACTIVE_PINS_SHA256` in `.github/workflows/ci.yml`), and `.github/CODEOWNERS` requires owner review for both.
The `evidence-integrity` job runs first; the matrix job `needs` it.

**Pins are generated from git blobs of approved commit d762f27** (baseline run commit 292d398), not from any working tree.

**Creating a new authorized matrix version (never edit matrix-v1):**
1. Add new evidence additively under a new directory; do not touch existing files.
2. Run `generate_pins.py --commit <approved sha> --out tests/integrity/pins/matrix-v2.pins` (refuses to overwrite).
3. In one owner-reviewed PR: add the v2 pins, update `ACTIVE_PINS` and `ACTIVE_PINS_SHA256` in ci.yml, and update the
   verifier's evidence roots if needed. matrix-v1.pins stays in the repo and must still verify against its own commit.
4. Record the PR, SHAs and hashes in the evidence README of the new version.

**Mutation tests:** `python3 tests/integrity/test_integrity_mutations.py -v` (modified manifest, modified/deleted/added/renamed
evidence, incorrect pinned hash, unchanged = pass).

**Known limitation:** a repo admin who edits ci.yml, the pin file and CODEOWNERS together can still change the anchors;
branch protection requiring owner review is the control. Not verified here.
