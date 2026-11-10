#!/usr/bin/env bash
# Proves the static checks FAIL on the defects they target (mutations applied to a scratch copy). Exit 0 only if every mutation is detected.
set -u; cd "$(dirname "$0")/../.."; rc=0; T=$(mktemp -d)
run() { # $1 name, $2 expected code, rest: shell snippet applied inside the scratch tree
  rm -rf "$T/w"; mkdir -p "$T/w/tests" "$T/w/supabase"; cp -r tests/static "$T/w/tests/"; cp -r supabase/migrations supabase/functions "$T/w/supabase/"
  ( cd "$T/w" && eval "$3" ) ; out=$(python3 "$T/w/tests/static/check_part_de.py" 2>&1); code=$?
  if [ "$code" = 1 ] && echo "$out" | grep -q "$2"; then echo "DETECTED $1"; else echo "NOT DETECTED $1 (exit $code): $out"; rc=1; fi
}
run "S1 later migration redefines the verifier" "S1 aios_final_verify" "echo 'create or replace function private.aios_final_verify(boolean,boolean,text) returns jsonb language sql as \$\$ select 1 \$\$;' > supabase/migrations/20261201000000_x.sql"
run "S1 later migration redefines the drift check" "S1 aios_guard_drift" "echo 'create or replace function private.aios_guard_drift() returns jsonb language sql as \$\$ select 1 \$\$;' > supabase/migrations/20261201000000_x.sql"
run "S1 later migration drops the canonical hash" "S1 aios_audit_canonical_hash" "echo 'drop function private.aios_audit_canonical_hash(public.aios_audit_events,text);' > supabase/migrations/20261201000000_x.sql"
run "S2 definer without search_path" "S2" "sed -i \"0,/set search_path = ''/s//set timezone = 'UTC'/\" supabase/migrations/*restoration_part_d.sql"
run "S3 grant to authenticated" "S3" "echo 'grant execute on function private.aios_restoration_open(text,text,interval) to authenticated;' >> supabase/migrations/*restoration_part_d.sql"
run "S3 grant to public" "S3" "echo 'grant select on private.aios_audit_anchors to public;' >> supabase/migrations/*anchoring_part_e.sql"
run "S4 JWT-claim authorization" "S4" "echo 'select auth.role();' >> supabase/migrations/*restoration_part_d.sql"
run "S5 notice that could echo a credential" "S5" "echo \"do \\\$\\\$ begin raise notice 'x'; end \\\$\\\$;\" >> supabase/migrations/*restoration_part_d.sql"
run "S6 function logs a token" "S6" "echo 'console.log(\"t\", token);' >> supabase/functions/audit-anchor/core.ts"
rm -rf "$T"; [ $rc = 0 ] && echo "STATIC SELFTEST: all mutations detected" || echo "STATIC SELFTEST: FAILURES"; exit $rc
