#!/usr/bin/env bash
# D1 acceptance matrix for scripts/recovery/restore_local.sh target preflight.
#
# Real PostgreSQL, disposable loopback databases only. Connection URI comes from the
# environment (never argv/logs). Every database name used here is created by this run
# and is removed by this run; a pre-existing database with a matching name makes the
# run fail instead of being reused or dropped.
#
# What is asserted:
#   * clean empty destination restores and validates;
#   * extension-owned objects (types, operators, operator classes/families, text-search
#     objects, functions) in the destination are NOT false positives;
#   * each enumerated conflict class is rejected by the emptiness guard, names the
#     offending object, and leaves the destination byte-identical (full pg_dump hash);
#   * conflicts spread over several schemas are all reported;
#   * a collision the preflight does not enumerate is stopped by pg_restore's
#     single transaction and leaves the destination byte-identical.
set -Eeuo pipefail
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
: "${AIOS_TEST_DB_URL:?AIOS_TEST_DB_URL must be supplied through the environment}"
for c in python3 createdb dropdb psql pg_dump pg_restore; do command -v "$c" >/dev/null || fail "$c is required"; done

repo="$(cd "$(dirname "$0")/../.." && pwd -P)"
restore_sh="$repo/scripts/recovery/restore_local.sh"
validate_sh="$repo/scripts/recovery/validate_local_restore.sh"
export_sh="$repo/scripts/recovery/export_logical.sh"
preflight_sql="$repo/scripts/recovery/preflight_target_empty.sql"

tmp="$(mktemp -d /tmp/aios-preflight-matrix.XXXXXX)"
chmod 700 "$tmp"
created_dbs=()
cleanup() {
  rc=$?
  set +e
  if [[ -f "$tmp/connection.env" ]]; then
    # shellcheck disable=SC1090
    source "$tmp/connection.env"
    for db in "${created_dbs[@]:-}"; do
      [[ -n "$db" ]] && PGUSER="$ADMIN_USER" PGDATABASE=postgres dropdb "$db" >/dev/null 2>&1
    done
  fi
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT

python3 - "$tmp" <<'PY'
import os, shlex, sys
from urllib.parse import urlsplit, unquote
base = sys.argv[1]
u = urlsplit(os.environ["AIOS_TEST_DB_URL"])
host = u.hostname or ""
if host not in ("127.0.0.1", "localhost", "::1"):
    raise SystemExit("matrix requires a loopback disposable PostgreSQL instance")
port = u.port or 5432
user = unquote(u.username or "")
password = unquote(u.password or "")
if not user or not password:
    raise SystemExit("database URL is missing user/password")
esc = lambda s: s.replace("\\", "\\\\").replace(":", "\\:")
pgpass = os.path.join(base, "pgpass")
with open(pgpass, "w", encoding="utf-8") as f:
    for name in {user, "supabase_admin"}:
        f.write(f"{host}:{port}:*:{name}:{esc(password)}\n")
os.chmod(pgpass, 0o600)
# ADMIN_USER creates databases and fixture objects that require a real superuser.
admin = "supabase_admin" if user != "supabase_admin" else user
env = {"PGHOST": host, "PGPORT": str(port), "PGPASSFILE": pgpass, "PGSSLMODE": "disable",
       "ADMIN_USER": admin, "RESTORE_USER": user}
with open(os.path.join(base, "connection.env"), "w", encoding="utf-8") as f:
    for k, v in env.items():
        f.write(f"export {k}={shlex.quote(v)}\n")
PY
# shellcheck disable=SC1091
source "$tmp/connection.env"

admin_sql() { PGUSER="$ADMIN_USER" PGDATABASE="$1" psql -X -q -v ON_ERROR_STOP=1 -c "$2" >/dev/null; }
# Same role that performs the restore, so objects it must later COMMENT ON / reuse are owned by it.
restore_user_sql() { PGUSER="$RESTORE_USER" PGDATABASE="$1" psql -X -q -v ON_ERROR_STOP=1 -c "$2" >/dev/null; }
newdb() {
  PGUSER="$ADMIN_USER" PGDATABASE=postgres createdb --owner="$RESTORE_USER" "$1"
  created_dbs+=("$1")
}
# Full schema+data dump hash. Recent pg_dump releases emit a random per-run
# "\restrict <token>" / "\unrestrict <token>" pair; exactly those two lines are removed
# so the hash is stable on an untouched database. Everything else is hashed.
fingerprint() {
  PGUSER="$ADMIN_USER" PGDATABASE="$1" pg_dump --no-owner --no-acl \
    | python3 -c 'import hashlib,re,sys
data = sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\n")
kept = [l for l in data if not re.match(r"^\\(un)?restrict [A-Za-z0-9]+$", l)]
print(hashlib.sha256("\n".join(kept).encode("utf-8", "surrogateescape")).hexdigest())'
}
preflight_rows() {  # prints the preflight result for database $1; fails if the query itself fails
  local out
  out="$(PGUSER="$ADMIN_USER" PGDATABASE="$1" psql -X -q -v ON_ERROR_STOP=1 -At -f "$preflight_sql")" \
    || fail "preflight query errored on $1 (an error is never an acceptable 'clean' result)"
  printf '%s' "$out"
}
run_restore() {  # run_restore <db> <export-dir> <logfile>; returns restore_local.sh's status
  PGUSER="$RESTORE_USER" PGDATABASE="$1" bash "$restore_sh" "$2" >"$3" 2>&1
}

passed=0
note() { passed=$((passed + 1)); printf 'PASS [%02d]: %s\n' "$passed" "$*"; }

# ---------------------------------------------------------------- source fixtures
newdb aios_pf_src
admin_sql aios_pf_src "
create extension if not exists pgcrypto;
create schema private;
create table public.aios_fixture (id uuid primary key default gen_random_uuid(), label text not null);
alter table public.aios_fixture enable row level security;
create policy aios_fixture_deny_all on public.aios_fixture for all using (false) with check (false);
create table public.aios_audit_events (id uuid primary key default gen_random_uuid(), organization_id uuid not null, event_type text not null);
create function private.audit_fixture_guard() returns trigger language plpgsql set search_path = '' as \$\$ begin return new; end; \$\$;
create trigger trg_aios_audit_hash before insert on public.aios_audit_events for each row execute function private.audit_fixture_guard();
create trigger trg_aios_audit_immutable_update before update on public.aios_audit_events for each row execute function private.audit_fixture_guard();
create trigger trg_aios_audit_immutable_delete before delete on public.aios_audit_events for each row execute function private.audit_fixture_guard();
create trigger trg_aios_audit_no_truncate before truncate on public.aios_audit_events for each statement execute function private.audit_fixture_guard();
create function private.verify_audit_chain(p_org uuid) returns jsonb language sql immutable set search_path = '' as \$\$ select jsonb_build_object('valid', true) \$\$;
insert into public.aios_fixture(label) values ('one'),('two'),('three');
insert into public.aios_audit_events(organization_id,event_type) values ('00000000-0000-4000-8000-000000000001','a'),('00000000-0000-4000-8000-000000000001','b');
"
PGUSER="$RESTORE_USER" PGDATABASE=aios_pf_src AIOS_EXPORT_APPROVAL=NONPRODUCTION bash "$export_sh" "$tmp/export" >"$tmp/export.log" 2>&1 \
  || { cat "$tmp/export.log" >&2; fail "fixture export failed"; }
export_dir="$tmp/export/aios-logical-export"

# Second source whose archive carries a PUBLICATION, a class the preflight does not enumerate.
newdb aios_pf_src_pub
admin_sql aios_pf_src_pub "
create schema pf_marker;
create table public.pf_pub_t (id int primary key);
create publication pf_pub for table public.pf_pub_t;
"
PGUSER="$RESTORE_USER" PGDATABASE=aios_pf_src_pub AIOS_EXPORT_APPROVAL=NONPRODUCTION bash "$export_sh" "$tmp/export_pub" >"$tmp/export_pub.log" 2>&1 \
  || { cat "$tmp/export_pub.log" >&2; fail "publication fixture export failed"; }
export_pub_dir="$tmp/export_pub/aios-logical-export"
grep -q 'pf_pub' <(pg_restore --list "$export_pub_dir/database.dump") || fail "publication fixture archive does not contain the publication"

# ---------------------------------------------------------------- fingerprint sensitivity
# The "byte-identical" assertions below are only meaningful if the hash is stable on an
# untouched database AND changes when the database changes.
newdb aios_pf_fp_probe
admin_sql aios_pf_fp_probe "create table public.pf_probe (id int)"
fp_a="$(fingerprint aios_pf_fp_probe)"; fp_b="$(fingerprint aios_pf_fp_probe)"
[[ "$fp_a" == "$fp_b" ]] || fail "fingerprint is not stable on an untouched database"
admin_sql aios_pf_fp_probe "alter table public.pf_probe add column extra text"
[[ "$(fingerprint aios_pf_fp_probe)" != "$fp_a" ]] || fail "fingerprint did not change after a schema change (cannot detect mutation)"
admin_sql aios_pf_fp_probe "insert into public.pf_probe(id) values (1)"
fp_c="$(fingerprint aios_pf_fp_probe)"
admin_sql aios_pf_fp_probe "update public.pf_probe set id = 2"
[[ "$(fingerprint aios_pf_fp_probe)" != "$fp_c" ]] || fail "fingerprint did not change after a data change"
note "destination fingerprint is stable when untouched and changes on schema and data edits"

# ---------------------------------------------------------------- positive: clean destination
newdb aios_restore_pf_clean
rows="$(preflight_rows aios_restore_pf_clean)"
[[ -z "$rows" ]] || fail "clean destination reported conflicts: $rows"
run_restore aios_restore_pf_clean "$export_dir" "$tmp/clean.log" || { cat "$tmp/clean.log" >&2; fail "clean destination restore failed"; }
PGUSER="$RESTORE_USER" PGDATABASE=aios_restore_pf_clean bash "$validate_sh" "$export_dir" >"$tmp/clean-validate.log" 2>&1 \
  || { cat "$tmp/clean-validate.log" >&2; fail "clean restore failed structural validation"; }
counts="$(PGUSER="$ADMIN_USER" PGDATABASE=aios_restore_pf_clean psql -X -v ON_ERROR_STOP=1 -AtF '|' -c 'select (select count(*) from public.aios_fixture),(select count(*) from public.aios_audit_events)')"
[[ "$counts" == "3|2" ]] || fail "clean restore row counts wrong: $counts"
note "clean empty destination: preflight 0 rows, restore + structural validation + row counts 3|2"

# ---------------------------------------------------------------- positive: extension-owned objects
newdb aios_restore_pf_ext
restore_user_sql aios_restore_pf_ext "create extension pgcrypto; create extension hstore; create extension pg_trgm; create extension unaccent"
ext_objects="$(PGUSER="$ADMIN_USER" PGDATABASE=aios_restore_pf_ext psql -X -v ON_ERROR_STOP=1 -At -c "
  select (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public')
       + (select count(*) from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public')
       + (select count(*) from pg_operator o join pg_namespace n on n.oid=o.oprnamespace where n.nspname='public')
       + (select count(*) from pg_opclass o join pg_namespace n on n.oid=o.opcnamespace where n.nspname='public')
       + (select count(*) from pg_opfamily o join pg_namespace n on n.oid=o.opfnamespace where n.nspname='public')
       + (select count(*) from pg_ts_dict o join pg_namespace n on n.oid=o.dictnamespace where n.nspname='public')
       + (select count(*) from pg_ts_template o join pg_namespace n on n.oid=o.tmplnamespace where n.nspname='public')")"
[[ "$ext_objects" -gt 50 ]] || fail "extension fixture is not meaningful: only $ext_objects extension-owned objects present in public"
rows="$(preflight_rows aios_restore_pf_ext)"
[[ -z "$rows" ]] || fail "extension-owned objects were reported as user objects (false positive): $rows"
run_restore aios_restore_pf_ext "$export_dir" "$tmp/ext.log" || { cat "$tmp/ext.log" >&2; fail "restore into destination with extension-owned objects failed"; }
PGUSER="$RESTORE_USER" PGDATABASE=aios_restore_pf_ext bash "$validate_sh" "$export_dir" >/dev/null 2>&1 || fail "restore into extension destination failed validation"
for e in hstore pg_trgm unaccent pgcrypto; do
  [[ "$(PGUSER="$ADMIN_USER" PGDATABASE=aios_restore_pf_ext psql -X -At -c "select count(*) from pg_extension where extname='$e'")" == "1" ]] || fail "pre-existing extension $e was altered by restore"
done
note "extension-owned objects (pgcrypto, hstore, pg_trgm, unaccent; $ext_objects objects in public) are not false positives; restore succeeds"

# ---------------------------------------------------------------- negative: one database per conflict
expect_conflict() {  # expect_conflict <case> <setup-sql> <expected-row> [<expected-row>...]
  local name="$1" setup="$2"; shift 2
  local db="aios_restore_pf_${name}"
  newdb "$db"
  admin_sql "$db" "$setup"
  local before after rows log="$tmp/${name}.log"
  before="$(fingerprint "$db")"
  rows="$(preflight_rows "$db")"
  for want in "$@"; do
    grep -Fxq -- "$want" <<<"$rows" || fail "[$name] preflight did not report '$want'. Reported: $(tr '\n' ';' <<<"$rows")"
  done
  if run_restore "$db" "$export_dir" "$log"; then fail "[$name] restore was ACCEPTED into a conflicting destination"; fi
  grep -q 'target database is not empty' "$log" || { cat "$log" >&2; fail "[$name] rejection did not come from the emptiness guard"; }
  for want in "$@"; do
    grep -Fq -- "$want" "$log" || { cat "$log" >&2; fail "[$name] error output does not name '$want'"; }
  done
  after="$(fingerprint "$db")"
  [[ "$before" == "$after" ]] || fail "[$name] destination changed after rejected restore"
  note "$name rejected by emptiness guard, names $*, destination byte-identical"
}

expect_conflict table            "create table public.pf_table (id int)"                                       'relation[r]:public.pf_table'
expect_conflict partitioned      "create table public.pf_part (id bigint) partition by range (id)"             'relation[p]:public.pf_part'
expect_conflict view             "create view public.pf_view as select 1 as x"                                 'relation[v]:public.pf_view'
expect_conflict matview          "create materialized view public.pf_mv as select 1 as x"                      'relation[m]:public.pf_mv'
expect_conflict sequence         "create sequence public.pf_seq"                                               'relation[S]:public.pf_seq'
expect_conflict function         "create function public.pf_fn() returns int language sql as 'select 1'"       'routine[f]:public.pf_fn()'
expect_conflict procedure        "create procedure public.pf_proc() language sql as 'select 1'"                'routine[p]:public.pf_proc()'
expect_conflict aggregate        "create aggregate public.pf_agg(int) (sfunc = int4pl, stype = int)"           'routine[a]:public.pf_agg(integer)'
expect_conflict enum_type        "create type public.pf_enum as enum ('a')"                                    'type[e]:public.pf_enum'
expect_conflict composite_type   "create type public.pf_comp as (a int)"                                       'relation[c]:public.pf_comp'
expect_conflict domain           "create domain public.pf_dom as int"                                          'type[d]:public.pf_dom'
expect_conflict range_type       "create type public.pf_range as range (subtype = int4)"                       'type[r]:public.pf_range'
expect_conflict collation        "create collation public.pf_coll (provider = libc, locale = 'C')"             'collation:public.pf_coll'
expect_conflict conversion       "create conversion public.pf_conv for 'UTF8' to 'LATIN1' from utf8_to_iso8859_1" 'conversion:public.pf_conv'
expect_conflict operator         "create operator public.### (leftarg = int4, rightarg = int4, function = int4pl)" 'operator:public.###(integer,integer)'
expect_conflict operator_family  "create operator family public.pf_fam using btree"                            'operator_family:public.pf_fam'
expect_conflict operator_class   "create operator family public.pf_fam2 using btree; create operator class public.pf_opc for type int4 using btree family public.pf_fam2 as operator 1 <, operator 2 <=, operator 3 =, operator 4 >=, operator 5 >, function 1 btint4cmp(int4,int4)" 'operator_class:public.pf_opc' 'operator_family:public.pf_fam2'
expect_conflict ts_config        "create text search configuration public.pf_cfg (copy = pg_catalog.simple)"   'ts_configuration:public.pf_cfg'
expect_conflict ts_dictionary    "create text search dictionary public.pf_dict (template = pg_catalog.simple)"  'ts_dictionary:public.pf_dict'
expect_conflict ts_parser        "create text search parser public.pf_prs (start = prsd_start, gettoken = prsd_nexttoken, end = prsd_end, lextypes = prsd_lextype)" 'ts_parser:public.pf_prs'
expect_conflict ts_template      "create text search template public.pf_tpl (init = dsimple_init, lexize = dsimple_lexize)" 'ts_template:public.pf_tpl'
expect_conflict ext_statistics   "create table public.pf_st (a int, b int); create statistics public.pf_stat on a, b from public.pf_st" 'extended_statistics:public.pf_stat'
expect_conflict empty_schema     "create schema pf_private"                                                    'schema:pf_private'
expect_conflict schema_function  "create schema pf_s; create function pf_s.f() returns int language sql as 'select 1'" 'schema:pf_s' 'routine[f]:pf_s.f()'
expect_conflict multi_schema     "create table public.pf_multi (id int); create schema pf_a; create function pf_a.pf_f() returns int language sql as 'select 1'; create schema pf_b; create type pf_b.pf_t as enum ('x')" \
  'relation[r]:public.pf_multi' 'schema:pf_a' 'routine[f]:pf_a.pf_f()' 'schema:pf_b' 'type[e]:pf_b.pf_t'

# A user object next to extension-owned ones: only the user object is reported.
newdb aios_restore_pf_ext_plus_user
admin_sql aios_restore_pf_ext_plus_user "create extension hstore; create extension pg_trgm; create table public.pf_user_table (id int)"
rows="$(preflight_rows aios_restore_pf_ext_plus_user)"
[[ "$rows" == 'relation[r]:public.pf_user_table' ]] || fail "extension objects leaked into the report next to a user object: $(tr '\n' ';' <<<"$rows")"
before="$(fingerprint aios_restore_pf_ext_plus_user)"
if run_restore aios_restore_pf_ext_plus_user "$export_dir" "$tmp/ext_plus_user.log"; then fail "restore accepted a user table next to extension objects"; fi
[[ "$(fingerprint aios_restore_pf_ext_plus_user)" == "$before" ]] || fail "destination changed after rejected restore (extension + user object)"
note "user object beside extension-owned objects: exactly 1 row reported, restore rejected, destination byte-identical"

# ---------------------------------------------------------------- failure atomicity
# (a) Backstop for anything the preflight misses: with the script's exact pg_restore
# flags, a collision on a populated destination must abort and roll back EVERYTHING,
# including objects created earlier in the same archive replay.
flags='pg_restore --exit-on-error --single-transaction --no-owner --no-acl --dbname "$PGDATABASE"'
grep -Fq -- "$flags" "$restore_sh" || fail "restore_local.sh no longer uses the exact transactional pg_restore invocation this test models"
newdb aios_restore_pf_backstop
admin_sql aios_restore_pf_backstop "create table public.aios_fixture (id int)"   # collides mid-replay, after the 'private' schema is created
before="$(fingerprint aios_restore_pf_backstop)"
if PGUSER="$ADMIN_USER" PGDATABASE=aios_restore_pf_backstop pg_restore --exit-on-error --single-transaction --no-owner --no-acl --dbname aios_restore_pf_backstop "$export_dir/database.dump" >"$tmp/backstop.log" 2>&1; then
  fail "pg_restore succeeded against a colliding destination"
fi
[[ "$(fingerprint aios_restore_pf_backstop)" == "$before" ]] || fail "failed pg_restore left partial state (single transaction did not roll back)"
[[ "$(PGUSER="$ADMIN_USER" PGDATABASE=aios_restore_pf_backstop psql -X -At -c "select count(*) from pg_namespace where nspname='private'")" == "0" ]] || fail "schema created earlier in the replay survived the failed restore"
note "pg_restore backstop: mid-replay collision aborts and rolls back all earlier work (destination byte-identical, no 'private' schema)"

# (b) End to end through the script for a class the preflight does NOT enumerate (publication).
newdb aios_restore_pf_publication
admin_sql aios_restore_pf_publication "create publication pf_pub"
rows="$(preflight_rows aios_restore_pf_publication)"
[[ -z "$rows" ]] || fail "unexpected preflight rows for a publication-only destination: $rows"
before="$(fingerprint aios_restore_pf_publication)"
if PGUSER="$RESTORE_USER" PGDATABASE=aios_restore_pf_publication bash "$restore_sh" "$export_pub_dir" >"$tmp/publication.log" 2>&1; then
  fail "restore succeeded although the destination already had the archive's publication"
fi
grep -qi 'already exists' "$tmp/publication.log" || { cat "$tmp/publication.log" >&2; fail "publication collision did not fail inside pg_restore"; }
[[ "$(fingerprint aios_restore_pf_publication)" == "$before" ]] || fail "failed restore altered the publication-only destination"
[[ "$(PGUSER="$ADMIN_USER" PGDATABASE=aios_restore_pf_publication psql -X -At -c "select count(*) from pg_namespace where nspname='pf_marker'")" == "0" ]] || fail "objects created before the collision survived the failed restore"
note "non-enumerated class (publication): preflight passes by design, restore_local.sh fails inside pg_restore and the destination is byte-identical"

printf 'RESTORE PREFLIGHT MATRIX: PASS (%d checks)\n' "$passed"
