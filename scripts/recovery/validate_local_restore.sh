#!/usr/bin/env bash
# Structural validation of an isolated local restore. Does not certify production recovery.
set -Eeuo pipefail
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
source "$(dirname "${BASH_SOURCE[0]}")/path_guard.sh"
for name in PGHOST PGPORT PGUSER PGDATABASE PGPASSFILE; do
  [[ -n "${!name:-}" ]] || fail "missing required libpq variable: $name"
done
case "$PGHOST" in localhost|127.0.0.1|::1) ;; *) fail "validation target must be loopback" ;; esac
[[ -z "${PGHOSTADDR:-}" || "$PGHOSTADDR" == 127.0.0.1 || "$PGHOSTADDR" == ::1 ]] || fail "PGHOSTADDR must be loopback"
[[ -z "${PGSERVICE:-}" && -z "${PGSERVICEFILE:-}" ]] || fail "PGSERVICE/PGSERVICEFILE are not allowed for isolated restore"
aios_guard_recovery_path existing "$PGPASSFILE"
[[ -r "$PGPASSFILE" ]] || fail "PGPASSFILE must be readable"
python3 - "$PGPASSFILE" <<'PY'
import os, stat, sys
if stat.S_IMODE(os.stat(sys.argv[1], follow_symlinks=False).st_mode) & 0o077:
    raise SystemExit("PGPASSFILE permissions must be 0600 or stricter")
PY
[[ "$PGDATABASE" == aios_restore_* ]] || fail "target database name must start with aios_restore_"
[[ $# -eq 1 ]] || fail "usage: $0 <export-directory>"
aios_guard_recovery_path existing_dir "$1"
src="$(cd "$1" && pwd -P)"
[[ -s "$src/extensions.tsv" ]] || fail "source extension inventory missing"
[[ -s "$src/source.txt" ]] || fail "source PostgreSQL version record missing"

# Compare exact extension versions, not only extension names.
ext_tmp="$(mktemp)"
trap 'rm -f "$ext_tmp"' EXIT
psql -X -v ON_ERROR_STOP=1 -AtF '|' -c "select extname, extversion from pg_extension order by extname" > "$ext_tmp"
while IFS=$'\t' read -r extname extversion; do
  [[ -n "$extname" ]] || continue
  grep -Fqx "$extname|$extversion" "$ext_tmp" || fail "required extension missing or version mismatch after restore: $extname (expected $extversion)"
done < "$src/extensions.tsv"

# Conservative compatibility policy: require the same PostgreSQL major version.
source_version="$(cut -d '|' -f 1 "$src/source.txt")"
target_version="$(psql -X -v ON_ERROR_STOP=1 -Atc "select current_setting('server_version')")"
source_major="$(printf '%s' "$source_version" | cut -d. -f1)"
target_major="$(printf '%s' "$target_version" | cut -d. -f1)"
[[ -n "$source_major" && "$source_major" == "$target_major" ]] || fail "PostgreSQL major version mismatch (source=$source_version target=$target_version)"

metrics="$(psql -X -v ON_ERROR_STOP=1 -AtF '|' -c "
select
 (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r'),
 (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relrowsecurity),
 (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and n.nspname='public' and c.relname='aios_audit_events'),
 (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.proname ilike '%verify%audit%chain%')
")"
IFS='|' read -r table_count rls_count audit_trigger_count verifier_count <<< "$metrics"
[[ "${table_count:-0}" -gt 0 ]] || fail "no public application tables found"
[[ "${rls_count:-0}" -gt 0 ]] || fail "no RLS-enabled public tables found"
[[ "${audit_trigger_count:-0}" -gt 0 ]] || fail "audit-event protection triggers missing"
[[ "${verifier_count:-0}" -gt 0 ]] || fail "audit-chain verifier function missing"
printf 'LOCAL RESTORE STRUCTURAL CHECKS: PASS\n'
printf 'database=%s\npublic_tables=%s\nrls_enabled_public_tables=%s\naudit_event_triggers=%s\naudit_verifier_functions=%s\n' "$PGDATABASE" "$table_count" "$rls_count" "$audit_trigger_count" "$verifier_count"
printf 'NOTE: cron schedules, secrets, external trust anchors, owner-session verification, and application-level behavior require separate reconstruction/verification.\n'
