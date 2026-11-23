#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail "usage: AGE_RECIPIENTS_FILE=/path/recipients.txt $0 INPUT OUTPUT.age"
command -v age >/dev/null 2>&1 || fail "age is required"
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || fail "sha256sum or shasum is required"

input=$1
output=$2
[[ -f "$input" && ! -L "$input" && -r "$input" ]] || fail "input must be a readable regular non-symlink file"
[[ -s "$input" ]] || fail "input is empty"
[[ -n "$output" && "$output" != "$input" ]] || fail "output must differ from input"
[[ ! -e "$output" && ! -L "$output" ]] || fail "refusing to overwrite existing output"
[[ -n "${AGE_RECIPIENTS_FILE:-}" ]] || fail "AGE_RECIPIENTS_FILE is required"
recipients=$AGE_RECIPIENTS_FILE
[[ -f "$recipients" && ! -L "$recipients" && -r "$recipients" && -s "$recipients" ]] || fail "recipient file must be readable, regular, non-symlink and non-empty"
[[ "$(stat -c '%a' "$recipients" 2>/dev/null || stat -f '%Lp' "$recipients" 2>/dev/null)" =~ ^(600|400|644|444)$ ]] || fail "recipient file permissions must be 0600, 0400, 0644 or 0444"

out_dir=$(dirname "$output")
mkdir -p "$out_dir"
tmp=$(mktemp "$out_dir/.age-encrypt.XXXXXX")
manifest_tmp=$(mktemp "$out_dir/.age-manifest.XXXXXX")
cleanup() { rm -f "$tmp" "$manifest_tmp"; }
trap cleanup EXIT HUP INT TERM

age -R "$recipients" -o "$tmp" "$input"
[[ -s "$tmp" ]] || fail "age produced an empty ciphertext"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$out_dir" && sha256sum "$(basename "$tmp")") > "$manifest_tmp"
else
  (cd "$out_dir" && shasum -a 256 "$(basename "$tmp")") > "$manifest_tmp"
fi
mv "$tmp" "$output"
manifest="${output}.sha256"
[[ ! -e "$manifest" && ! -L "$manifest" ]] || fail "refusing to overwrite existing manifest"
mv "$manifest_tmp" "$manifest"
trap - EXIT HUP INT TERM
printf 'Encrypted artifact created. Ciphertext SHA-256 manifest: %s\n' "$manifest"
