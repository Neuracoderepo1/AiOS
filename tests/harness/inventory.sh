#!/usr/bin/env bash
# Effective-definition inventory from a REPLAYED database (not migration text). Usage: inventory.sh <conninfo> <outdir>
set -euo pipefail
CONN="$1"; OUT="$2"; mkdir -p "$OUT/effective-functions" "$OUT/trigger-inventory" "$OUT/role-and-grant-inventory"
P() { psql "$CONN" -X -At -v ON_ERROR_STOP=1 "$@"; }
P -c "select n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('private','public') and (p.proname ~* 'audit|restoration|restorer|guard|invocation|approval|reap|mission|task|cron|verify|anchor|schedule' ) order by 1" > "$OUT/effective-functions/INDEX.txt"
while IFS= read -r sig; do
  f=$(printf '%s' "$sig" | tr -c 'A-Za-z0-9._()-' '_' | cut -c1-150)
  P -c "select pg_get_functiondef(to_regprocedure('$sig'))" > "$OUT/effective-functions/$f.sql" 2>/dev/null || true
done < "$OUT/effective-functions/INDEX.txt"
P -F $'\t' -c "select n.nspname, c.relname, t.tgname, t.tgenabled, pg_get_triggerdef(t.oid, true) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and n.nspname in ('public','private') order by 1,2,3" > "$OUT/trigger-inventory/all-triggers.tsv"
P -F $'\t' -c "select schema_name||'.'||table_name, trigger_name, expected_enabled, restorable, expected_function from private.aios_guarded_triggers order by 1,2" > "$OUT/trigger-inventory/guard-registry.tsv"
P -F $'\t' -c "select rolname, rolsuper, rolcanlogin, rolinherit, rolbypassrls, (select coalesce(string_agg(g.rolname, ','),'') from pg_auth_members m join pg_roles g on g.oid=m.roleid where m.member=r.oid) as member_of from pg_roles r where rolname !~ '^pg_' order by 1" > "$OUT/role-and-grant-inventory/roles.tsv"
P -F $'\t' -c "select n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')', p.prosecdef, pg_get_userbyid(p.proowner), coalesce(p.proacl::text,'<default: PUBLIC execute>'), coalesce(p.proconfig::text,'') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('private','public') and p.proname ~* 'restor|guard|audit_(anchor|verif|canon|chain|head|record|policy)|final_verify|scheduled_verify|schedule_check' order by 1" > "$OUT/role-and-grant-inventory/function-acls.tsv"
P -F $'\t' -c "select table_schema||'.'||table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants where table_schema in ('private','public') and table_name ~ 'audit|restoration|guarded|anchor|function_pins' and grantee not in ('postgres','supabase_admin','root') group by 1,2 order by 1,2" > "$OUT/role-and-grant-inventory/table-grants.tsv"
P -F $'\t' -c "select jobid, jobname, schedule, active, username, command from cron.job order by jobid" > "$OUT/role-and-grant-inventory/cron-jobs.tsv"
echo "inventory written to $OUT"
