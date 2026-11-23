#!/usr/bin/env bash
set -Eeuo pipefail
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 1 ]] || fail "usage: $0 ARTIFACT.sha256"
manifest=$1
[[ -f "$manifest" && ! -L "$manifest" && -r "$manifest" && -s "$manifest" ]] || fail "manifest must be a readable regular non-symlink file"
dir=$(cd "$(dirname "$manifest")" && pwd -P)
name=$(basename "$manifest")
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$dir" && sha256sum --strict -c "$name")
elif command -v shasum >/dev/null 2>&1; then
  (cd "$dir" && shasum -a 256 -c "$name")
else
  fail "sha256sum or shasum is required"
fi
