#!/usr/bin/env bash
# Usage: replay.sh <DB_NAME> [upto_migration_prefix]   Replays supabase/migrations on a local throwaway cluster; fails closed.
set -u
DBN="${1:?db name}"; UPTO="${2:-99999999999999}"; ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PSQL="su postgres -c"
su postgres -c "psql -v ON_ERROR_STOP=1 -qAt -c \"drop database if exists $DBN with (force)\" -c \"create database $DBN\"" >/dev/null || exit 2
su postgres -c "psql -d $DBN -v ON_ERROR_STOP=1 -q -f $ROOT/tests/harness/supabase_shim.sql" >/dev/null 2>/tmp/shim.err || { cat /tmp/shim.err; echo "SHIM FAILED"; exit 2; }
n=0; fail=0
for f in $(ls "$ROOT"/supabase/migrations/*.sql | sort); do
  v=$(basename "$f" | sed 's/_.*//'); [ "$v" -gt "$UPTO" ] && break
  if ! su postgres -c "psql -d $DBN -v ON_ERROR_STOP=1 -q -1 -f $f" >/dev/null 2>/tmp/mig.err; then echo "FAIL $(basename $f): $(head -c 400 /tmp/mig.err)"; fail=1; break; fi
  n=$((n+1))
done
echo "applied=$n fail=$fail"; exit $fail
