#!/usr/bin/env bash
# Structural validation of an isolated local restore. Does not certify production recovery.
set -Eeuo pipefail
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for name in PGHOST PGPORT PGUSER PGDATABASE PGPASSFILE; do
  [[ -n "${!name:-}" ]] || fail "missing required libpq variable: $name"
done
case "$PGHOST" in localhost|127.0.0.1|::1) ;; *) fail "validation target must be loopback" ;; esac
[[ "$PGDATABASE" == aios_restore_* ]] || fail "target database name must start with aios_restore_"
[[ $# -eq 1 ]] || fail "usage: $0 <export-directory>"
src="$(cd "$1" && pwd -P)"
[[ -s "$src/extensions.tsv" ]] || fail "source extension inventory missing"
ext_tmp="$(mktemp)"
trap 'rm -f "$ext_tmp"' EXIT
psql -X -v ON_ERROR_STOP=1 -Atc "select extname from pg_extension order by extname" > "$ext_tmp"
while IFS=$'\t' read -r extname extversion; do
  [[ -n "$extname" ]] || continue
  grep -Fxq "$extname" "$ext_tmp" || fail "required extension absent after restore: $extname"
done < "$src/extensions.tsv"
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
