#!/usr/bin/env bash
# Shared path policy for recovery helpers. All recovery inputs, key material,
# ciphertext and plaintext destinations must live outside the repository.
set -Eeuo pipefail

AIOS_RECOVERY_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export AIOS_RECOVERY_REPO_ROOT

aios_guard_recovery_path() {
  local mode=$1 path=$2
  python3 - "$AIOS_RECOVERY_REPO_ROOT" "$mode" "$path" <<'PY'
import os, sys
root, mode, path = sys.argv[1:]
if not os.path.isabs(path):
    raise SystemExit("ERROR: recovery paths must be absolute")
root = os.path.realpath(root, strict=True)
if mode == "existing":
    if os.path.islink(path):
        raise SystemExit("ERROR: recovery input/key paths cannot be symlinks")
    resolved = os.path.realpath(path, strict=True)
    if not os.path.isfile(resolved):
        raise SystemExit("ERROR: recovery input/key path must be a regular file")
elif mode == "new":
    if os.path.lexists(path):
        raise SystemExit("ERROR: recovery output already exists")
    parent = os.path.dirname(path)
    name = os.path.basename(path)
    if not name or name in (".", ".."):
        raise SystemExit("ERROR: invalid recovery output filename")
    resolved_parent = os.path.realpath(parent, strict=True)
    if not os.path.isdir(resolved_parent):
        raise SystemExit("ERROR: recovery output parent must already exist")
    resolved = os.path.join(resolved_parent, name)
else:
    raise SystemExit("ERROR: invalid recovery path policy mode")
try:
    inside = os.path.commonpath((root, resolved)) == root
except ValueError:
    inside = False
if inside:
    raise SystemExit("ERROR: recovery inputs, key material and outputs must remain outside the repository")
PY
}
