#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail "usage: AGE_IDENTITY_FILE=/secure/identity.txt $0 INPUT.age OUTPUT"
command -v age >/dev/null 2>&1 || fail "age is required"
cipher=$1
output=$2
[[ -f "$cipher" && ! -L "$cipher" && -r "$cipher" && -s "$cipher" ]] || fail "ciphertext must be a readable non-empty regular non-symlink file"
[[ -n "$output" && "$output" != "$cipher" ]] || fail "output must differ from input"
[[ ! -e "$output" && ! -L "$output" ]] || fail "refusing to overwrite existing output"
[[ -n "${AGE_IDENTITY_FILE:-}" ]] || fail "AGE_IDENTITY_FILE is required"
identity=$AGE_IDENTITY_FILE
[[ -f "$identity" && ! -L "$identity" && -r "$identity" && -s "$identity" ]] || fail "identity must be a readable regular non-symlink file"
mode=$(stat -c '%a' "$identity" 2>/dev/null || stat -f '%Lp' "$identity" 2>/dev/null) || fail "cannot inspect identity permissions"
[[ "$mode" == "600" || "$mode" == "400" ]] || fail "private identity file must have mode 0600 or 0400"

manifest="${cipher}.sha256"
[[ -f "$manifest" ]] || fail "ciphertext manifest missing"
bash "$(dirname "$0")/verify_manifest.sh" "$manifest"

out_dir=$(dirname "$output")
mkdir -p "$out_dir"
tmp=$(mktemp "$out_dir/.age-decrypt.XXXXXX")
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT HUP INT TERM
age -d -i "$identity" -o "$tmp" "$cipher"
[[ -s "$tmp" ]] || fail "decrypted output is empty"
mv "$tmp" "$output"
trap - EXIT HUP INT TERM
printf 'Ciphertext integrity verified and decryption completed. Plaintext path: %s\n' "$output"
