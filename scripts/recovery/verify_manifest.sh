#!/usr/bin/env bash
set -Eeuo pipefail
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 1 ]] || fail "usage: $0 ARTIFACT.sha256"
manifest=$1
[[ -f "$manifest" && ! -L "$manifest" && -r "$manifest" && -s "$manifest" ]] || fail "manifest must be a readable regular non-symlink file"
[[ "$manifest" == *.sha256 ]] || fail "manifest filename must end in .sha256"
dir=$(cd "$(dirname "$manifest")" && pwd -P)
manifest_name=$(basename "$manifest")
artifact_name=${manifest_name%.sha256}
[[ "$artifact_name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "artifact filename contains unsupported characters"
artifact="$dir/$artifact_name"
[[ -f "$artifact" && ! -L "$artifact" && -r "$artifact" && -s "$artifact" ]] || fail "manifest target must be a readable non-empty regular non-symlink file"
[[ $(wc -l < "$manifest" | tr -d ' ') == 1 ]] || fail "manifest must contain exactly one entry"
IFS= read -r entry < "$manifest" || fail "cannot read manifest entry"
[[ "$entry" =~ ^([0-9a-fA-F]{64})\ \ ([A-Za-z0-9._-]+)$ ]] || fail "manifest entry format is invalid"
expected_hash=${BASH_REMATCH[1]}
declared_name=${BASH_REMATCH[2]}
[[ "$declared_name" == "$artifact_name" ]] || fail "manifest filename does not match the artifact named by the manifest"
if command -v sha256sum >/dev/null 2>&1; then
  actual_hash=$(sha256sum "$artifact" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  actual_hash=$(shasum -a 256 "$artifact" | awk '{print $1}')
else
  fail "sha256sum or shasum is required"
fi
[[ "$actual_hash" == "$expected_hash" ]] || fail "SHA-256 mismatch for $artifact_name"
printf '%s: OK\n' "$artifact_name"
