# use the disposable local superuser as explicit fixture owner and restore operator
#!/usr/bin/env bash
# Real PostgreSQL logical export -> isolated restore -> structural/data validation.
# CI-only disposable databases; connection URI is read from environment, never argv or logs.
set -Eeuo pipefail
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
: "${AIOS_TEST_DB_URL:?AIOS_TEST_DB_URL must be supplied through the environment}"
command -v python3 >/dev/null || fail "python3 is required"
command -v createdb >/dev/null || fail "createdb is required"
command -v dropdb >/dev/null || fail "dropdb is required"
command -v psql >/dev/null || fail "psql is required"

tmp="$(mktemp -d /tmp/aios-recovery-roundtrip.XXXXXX)"
chmod 700 "$tmp"
created_export_fixture=0
created_restore_fixture=0
created_schema_guard=0
created_partition_guard=0
created_atomicity_guard=0
cleanup() {
  rc=$?
  set +e
  if [[ -f "$tmp/connection.env" ]]; then
    # shellcheck disable=SC1090
    source "$tmp/connection.env"
    # Remove only databases this invocation successfully created. Never pre-drop
    # or clean up a pre-existing local database with a matching fixture name.
    if [[ "$created_restore_fixture" == 1 ]]; then
      PGUSER=supabase_admin PGDATABASE=postgres dropdb aios_restore_ci >/dev/null 2>&1
    fi
    if [[ "$created_export_fixture" == 1 ]]; then
      PGUSER=supabase_admin PGDATABASE=postgres dropdb aios_export_fixture >/dev/null 2>&1
    fi
    if [[ "$created_schema_guard" == 1 ]]; then
      PGUSER=supabase_admin PGDATABASE=postgres dropdb aios_restore_schema_guard >/dev/null 2>&1
    fi
    if [[ "$created_partition_guard" == 1 ]]; then
      PGUSER=supabase_admin PGDATABASE=postgres dropdb aios_restore_partition_guard >/dev/null 2>&1
    fi
    if [[ "$created_atomicity_guard" == 1 ]]; then
      PGUSER=supabase_admin PGDATABASE=postgres dropdb aios_restore_atomicity_guard >/dev/null 2>&1
    fi
  fi
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT

python3 - "$tmp" <<'PY'
import os, shlex, stat, sys
from urllib.parse import urlsplit, unquote
base=sys.argv[1]
u=urlsplit(os.environ["AIOS_TEST_DB_URL"])
host=u.hostname or ""
if host not in ("127.0.0.1","localhost","::1"):
    raise SystemExit("roundtrip requires a loopback Supabase CI database")
port=u.port or 5432
user=unquote(u.username or "")
password=unquote(u.password or "")
if not user or not password:
    raise SystemExit("CI database URL is missing user/password")
def pgpass_escape(s):
    return s.replace("\\","\\\\").replace(":","\\:")
pgpass=os.path.join(base,"pgpass")
with open(pgpass,"w",encoding="utf-8") as f:
    f.write(f"{host}:{port}:*:{user}:{pgpass_escape(password)}\n")
    f.write(f"{host}:{port}:*:supabase_admin:{pgpass_escape(password)}\n")
os.chmod(pgpass,0o600)
env={
 "PGHOST":host,"PGPORT":str(port),"PGUSER":"supabase_admin",
 "PGDATABASE":"postgres","PGPASSFILE":pgpass,"PGSSLMODE":"disable"
}
with open(os.path.join(base,"connection.env"),"w",encoding="utf-8") as f:
    for k,v in env.items(): f.write(f"export {k}={shlex.quote(v)}\n")
PY
# shellcheck disable=SC1091
source "$tmp/connection.env"
# Never delete pre-existing databases. Creation must fail closed on a name
# collision; cleanup removes only databases created successfully below.
createdb --owner=postgres aios_export_fixture
created_export_fixture=1
createdb --owner=postgres aios_restore_ci
created_restore_fixture=1
PGUSER=postgres PGDATABASE=aios_export_fixture psql -X -v ON_ERROR_STOP=1 <<'SQL'
create extension if not exists pgcrypto;
create schema private;
create table public.aios_fixture (
  id uuid primary key default gen_random_uuid(),
  label text not null
);
alter table public.aios_fixture enable row level security;
create policy aios_fixture_deny_all on public.aios_fixture
  for all using (false) with check (false);
create table public.aios_audit_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_type text not null
);
create function private.audit_fixture_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  return new;
end;
$$;
create trigger trg_aios_audit_hash before insert on public.aios_audit_events
  for each row execute function private.audit_fixture_guard();
create trigger trg_aios_audit_immutable_update before update on public.aios_audit_events
  for each row execute function private.audit_fixture_guard();
create trigger trg_aios_audit_immutable_delete before delete on public.aios_audit_events
  for each row execute function private.audit_fixture_guard();
create trigger trg_aios_audit_no_truncate before truncate on public.aios_audit_events
  for each statement execute function private.audit_fixture_guard();
create function private.verify_audit_chain(p_org uuid)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('valid', true, 'fixture', true)
$$;
insert into public.aios_fixture(label) values ('roundtrip-one'),('roundtrip-two'),('roundtrip-three');
insert into public.aios_audit_events(organization_id,event_type)
values ('00000000-0000-4000-8000-000000000001','fixture.created'),
       ('00000000-0000-4000-8000-000000000001','fixture.updated');
SQL

PGUSER=postgres PGDATABASE=aios_export_fixture \
  AIOS_EXPORT_APPROVAL=NONPRODUCTION \
  bash scripts/recovery/export_logical.sh "$tmp/export"

# Exercise the transactional fallback for a restore-time conflict outside the
# preflight's explicitly enumerated catalog classes. This test deliberately calls
# pg_restore with the exact production wrapper flags, bypassing only the preflight,
# so a duplicate relation is encountered after the archive has begun creating
# earlier objects. The single transaction must roll those earlier creations back.
createdb --owner=postgres aios_restore_atomicity_guard
created_atomicity_guard=1
PGUSER=postgres PGDATABASE=aios_restore_atomicity_guard psql -X -v ON_ERROR_STOP=1 <<'SQL'
create table public.aios_fixture (sentinel text primary key);
insert into public.aios_fixture values ('pre-existing-row');
SQL
if PGUSER=postgres PGDATABASE=aios_restore_atomicity_guard \
  pg_restore --exit-on-error --single-transaction --no-owner --no-acl \
    --dbname aios_restore_atomicity_guard "$tmp/export/aios-logical-export/database.dump" \
    >"$tmp/atomicity-guard.log" 2>&1; then
  fail "single-transaction restore unexpectedly accepted a duplicate relation"
fi
grep -Eiq 'already exists|duplicate key|conflict' "$tmp/atomicity-guard.log" || \
  fail "atomicity test failed for an unexpected reason: $(tail -n 20 "$tmp/atomicity-guard.log")"
atomicity_private_schema="$(PGUSER=postgres PGDATABASE=aios_restore_atomicity_guard psql -X -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_namespace where nspname='private'")"
[[ "$atomicity_private_schema" == "0" ]] || fail "failed restore left the archive's earlier private schema behind"
atomicity_extension="$(PGUSER=postgres PGDATABASE=aios_restore_atomicity_guard psql -X -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_extension where extname='pgcrypto'")"
[[ "$atomicity_extension" == "0" ]] || fail "failed restore left the archive's earlier extension behind"
atomicity_row="$(PGUSER=postgres PGDATABASE=aios_restore_atomicity_guard psql -X -v ON_ERROR_STOP=1 -Atc "select sentinel from public.aios_fixture")"
[[ "$atomicity_row" == "pre-existing-row" ]] || fail "failed restore changed the pre-existing relation"
printf 'PASS: unenumerated restore-time conflict rolled back atomically; existing object preserved\\n'

createdb --owner=postgres aios_restore_schema_guard
created_schema_guard=1
PGUSER=postgres PGDATABASE=aios_restore_schema_guard psql -X -v ON_ERROR_STOP=1 -c 'create schema preexisting_private'
if PGUSER=postgres PGDATABASE=aios_restore_schema_guard bash scripts/recovery/restore_local.sh "$tmp/export/aios-logical-export" >"$tmp/schema-guard.log" 2>&1; then
  fail "restore accepted a target with a pre-existing custom schema"
fi
grep -q 'target database is not empty' "$tmp/schema-guard.log" || fail "custom-schema rejection did not come from the emptiness guard"
schema_survived="$(PGUSER=postgres PGDATABASE=aios_restore_schema_guard psql -X -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_namespace where nspname='preexisting_private'")"
[[ "$schema_survived" == "1" ]] || fail "restore preflight altered the pre-existing custom schema"
createdb --owner=postgres aios_restore_partition_guard
created_partition_guard=1
PGUSER=postgres PGDATABASE=aios_restore_partition_guard psql -X -v ON_ERROR_STOP=1 -c 'create table public.preexisting_partitioned (id bigint) partition by range (id)'
if PGUSER=postgres PGDATABASE=aios_restore_partition_guard bash scripts/recovery/restore_local.sh "$tmp/export/aios-logical-export" >"$tmp/partition-guard.log" 2>&1; then
  fail "restore accepted a target with a pre-existing partitioned table"
fi
grep -q 'target database is not empty' "$tmp/partition-guard.log" || fail "partitioned-table rejection did not come from the emptiness guard"
partition_survived="$(PGUSER=postgres PGDATABASE=aios_restore_partition_guard psql -X -v ON_ERROR_STOP=1 -Atc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='preexisting_partitioned' and c.relkind='p'")"
[[ "$partition_survived" == "1" ]] || fail "restore preflight altered the pre-existing partitioned table"
PGUSER=postgres PGDATABASE=aios_restore_ci \
  bash scripts/recovery/restore_local.sh "$tmp/export/aios-logical-export"
PGUSER=postgres PGDATABASE=aios_restore_ci \
  bash scripts/recovery/validate_local_restore.sh "$tmp/export/aios-logical-export"

source_counts="$(PGUSER=postgres PGDATABASE=aios_export_fixture psql -X -v ON_ERROR_STOP=1 -AtF '|' -c "select (select count(*) from public.aios_fixture),(select count(*) from public.aios_audit_events)")"
restored_counts="$(PGUSER=postgres PGDATABASE=aios_restore_ci psql -X -v ON_ERROR_STOP=1 -AtF '|' -c "select (select count(*) from public.aios_fixture),(select count(*) from public.aios_audit_events)")"
[[ "$source_counts" == "$restored_counts" ]] || fail "row-count mismatch: source=$source_counts restored=$restored_counts"
[[ "$source_counts" == "3|2" ]] || fail "unexpected source fixture row counts: $source_counts"
printf 'REAL POSTGRESQL LOGICAL EXPORT / ISOLATED RESTORE: PASS\n'
printf 'source_rows=%s restored_rows=%s\n' "$source_counts" "$restored_counts"
