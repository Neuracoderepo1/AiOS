#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail "usage: AGE_RECIPIENTS_FILE=/path/recipients.txt $0 INPUT OUTPUT.age"
command -v age >/dev/null 2>&1 || fail "age is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || fail "sha256sum or shasum is required"
input=$1; output=$2
[[ -f "$input" && ! -L "$input" && -r "$input" ]] || fail "input must be a readable regular non-symlink file"
[[ -s "$input" ]] || fail "input is empty"
[[ -n "$output" && "$output" != "$input" ]] || fail "output must differ from input"
[[ ! -e "$output" && ! -L "$output" ]] || fail "refusing to overwrite existing output"
manifest="${output}.sha256"
[[ ! -e "$manifest" && ! -L "$manifest" ]] || fail "refusing to overwrite existing manifest"
[[ -n "${AGE_RECIPIENTS_FILE:-}" ]] || fail "AGE_RECIPIENTS_FILE is required"
recipients=$AGE_RECIPIENTS_FILE
[[ -f "$recipients" && ! -L "$recipients" && -r "$recipients" && -s "$recipients" ]] || fail "recipient file must be readable, regular, non-symlink and non-empty"
mode=$(stat -c '%a' "$recipients" 2>/dev/null || stat -f '%Lp' "$recipients" 2>/dev/null) || fail "cannot inspect recipient permissions"
[[ "$mode" =~ ^(600|400|644|444)$ ]] || fail "recipient file permissions must be 0600, 0400, 0644 or 0444"
out_dir=$(dirname "$output"); mkdir -p "$out_dir"
# Conservative free-space preflight: allow input size plus 1 MiB for ciphertext/temp overhead.
python3 - "$input" "$out_dir" "${AIOS_TEST_MIN_FREE_KB:-0}" <<'PY'
import os, shutil, sys
source, target, forced = sys.argv[1:]
required = os.path.getsize(source) + 1024 * 1024
available = shutil.disk_usage(target).free
if int(forced) > 0:
    available = 0 if int(forced) == 1 else available
if available < required:
    raise SystemExit("ERROR: insufficient free space for encrypted artifact and temporary output")
PY
tmp=$(mktemp "$out_dir/.age-encrypt.XXXXXX")
manifest_tmp=$(mktemp "$out_dir/.age-manifest.XXXXXX")
cleanup() { rm -f "$tmp" "$manifest_tmp"; }
trap cleanup EXIT HUP INT TERM
age -R "$recipients" -o "$tmp" "$input"
[[ -s "$tmp" ]] || fail "age produced an empty ciphertext"
base=$(basename "$output")
if command -v sha256sum >/dev/null 2>&1; then
  hash=$(sha256sum "$tmp" | awk '{print $1}')
else
  hash=$(shasum -a 256 "$tmp" | awk '{print $1}')
fi
printf '%s  %s\n' "$hash" "$base" > "$manifest_tmp"
mv "$tmp" "$output"
mv "$manifest_tmp" "$manifest"
trap - EXIT HUP INT TERM
printf 'Encrypted artifact created. Ciphertext SHA-256 manifest: %s\n' "$manifest"
