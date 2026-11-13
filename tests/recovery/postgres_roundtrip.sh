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
cleanup() {
  rc=$?
  set +e
  if [[ -f "$tmp/connection.env" ]]; then
    # shellcheck disable=SC1090
    source "$tmp/connection.env"
    PGUSER=supabase_admin PGDATABASE=postgres dropdb --if-exists aios_restore_ci >/dev/null 2>&1
    PGUSER=supabase_admin PGDATABASE=postgres dropdb --if-exists aios_export_fixture >/dev/null 2>&1
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
# Only disposable local CI databases are created/dropped by this test.
dropdb --if-exists aios_export_fixture >/dev/null 2>&1 || true
dropdb --if-exists aios_restore_ci >/dev/null 2>&1 || true
createdb --owner=postgres aios_export_fixture
createdb aios_restore_ci

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
PGUSER=supabase_admin PGDATABASE=aios_restore_ci \
  bash scripts/recovery/restore_local.sh "$tmp/export/aios-logical-export"
PGUSER=supabase_admin PGDATABASE=aios_restore_ci \
  bash scripts/recovery/validate_local_restore.sh "$tmp/export/aios-logical-export"

source_counts="$(PGUSER=postgres PGDATABASE=aios_export_fixture psql -X -v ON_ERROR_STOP=1 -AtF '|' -c "select (select count(*) from public.aios_fixture),(select count(*) from public.aios_audit_events)")"
restored_counts="$(PGUSER=supabase_admin PGDATABASE=aios_restore_ci psql -X -v ON_ERROR_STOP=1 -AtF '|' -c "select (select count(*) from public.aios_fixture),(select count(*) from public.aios_audit_events)")"
[[ "$source_counts" == "$restored_counts" ]] || fail "row-count mismatch: source=$source_counts restored=$restored_counts"
[[ "$source_counts" == "3|2" ]] || fail "unexpected source fixture row counts: $source_counts"
printf 'REAL POSTGRESQL LOGICAL EXPORT / ISOLATED RESTORE: PASS\n'
printf 'source_rows=%s restored_rows=%s\n' "$source_counts" "$restored_counts"
