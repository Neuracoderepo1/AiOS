#!/usr/bin/env bash
# Self-test for the smoke suite: proves each check goes red for the defect it exists to catch, and that the runner fails closed.
# Usage: scripts/smoke/selftest.sh <DB_URL>     THROWAWAY database built from supabase/migrations only (superuser required).
# Every database mutation happens inside a transaction that is rolled back; nothing is committed.
set -uo pipefail
DB="${1:?usage: selftest.sh <throwaway DB_URL>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; root="$(cd "$here/../.." && pwd)"
fails=0; total=0
psqlq() { PGOPTIONS= psql "$DB" -X -q -A -F'|' -t -v ON_ERROR_STOP=1 "$@"; }
[ "$(psqlq -c "select rolsuper from pg_roles where rolname = current_user")" = t ] || { echo "selftest needs a superuser on a throwaway database"; exit 2; }
# The audit TRUNCATE guard (proposal 001) is now part of supabase/migrations, so a clean replay HAS it. Cases that need the
# guard absent create that state explicitly (inside the rolled-back transaction) instead of assuming the DB lacks it.
noguard="drop trigger if exists trg_aios_audit_no_truncate on public.aios_audit_events;
drop function if exists private.aios_audit_no_truncate();
grant truncate on public.aios_audit_events to service_role;"
guard_live="$(psqlq -c "select exists (select 1 from pg_trigger where tgrelid = 'public.aios_audit_events'::regclass and tgname = 'trg_aios_audit_no_truncate') and not has_table_privilege('service_role', 'public.aios_audit_events', 'TRUNCATE')")"
proposal="$(sed '/^begin;$/d;/^commit;$/d' "$root/docs/certification/proposals/001-audit-truncate-guard.sql")"

pass() { total=$((total+1)); echo "  PASS $1"; }
fail() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }

# Baseline fixture: recent successful runs for every cron job (a throwaway DB has no cron history).
fixture="set local session_replication_role = replica;
insert into cron.job_run_details (jobid, status, start_time) select jobid, 'succeeded', now() - interval '1 minute' from cron.job;"

# run_sql <file> <defect-sql> [profile] [p001]  -> prints the check rows
run_sql() {
  local file="$1" defect="$2" profile="${3:-replay}" p001="${4:-0}"
  psqlq <<SQL
begin;
$fixture
$defect
set local session_replication_role = origin;
set local smoke.profile = '$profile';
set local smoke.proposal_001_applied = '$p001';
\i $here/$file
rollback;
SQL
}
status_of() { awk -F'|' -v id="$1" '{ split($1, p, " "); if (p[1] == id) { print $2; exit } }'; }

# case <label> <file> <check id> <expected status> <defect-sql> [profile] [p001]
case_() {
  local label="$1" file="$2" id="$3" want="$4" defect="$5" profile="${6:-replay}" p001="${7:-0}" out got
  out="$(run_sql "$file" "$defect" "$profile" "$p001" 2>&1)" || { fail "$label (query errored instead of reporting: $(head -c 200 <<<"$out" | tr '\n' ' '))"; return; }
  got="$(status_of "$id" <<<"$out")"
  if [ "$got" = "$want" ]; then pass "$label: $id=$got"; else fail "$label: $id expected $want, got '${got:-missing}'"; fi
}

echo "== A. baseline on a clean replay: every control PASS, known exceptions as documented"
base="$(run_sql smoke_readonly.sql "" 2>&1)" || { echo "baseline query failed: $base"; exit 1; }
for id in S01 S02 S03 S05 S07 S08 S09 S10 S12 S13 S14 S15 S16 S17 S18 S19 S23; do
  [ "$(status_of $id <<<"$base")" = PASS ] && pass "baseline $id PASS" || { fail "baseline $id not PASS: $(grep "^$id" <<<"$base" | cut -c1-200)"; }
done
s11_base=WARN; [ "$guard_live" = t ] && s11_base=PASS
for pair in S04:INFO S06:INFO S11:$s11_base S20:INFO S21:INFO S22:WARN; do
  id="${pair%%:*}"; want="${pair##*:}"; [ "$(status_of $id <<<"$base")" = "$want" ] && pass "baseline $id $want" || fail "baseline $id expected $want"
done

echo "== B. cron (S01-S03)"
case_ "duplicate expiry job"      smoke_readonly.sql S01 FAIL "select cron.schedule('selftest-dup', '*/5 * * * *', 'select private.aios_expire_stale_approvals()');"
case_ "reaper job inactive"       smoke_readonly.sql S01 FAIL "update cron.job set active = false where command ilike '%aios_reap_stale_tasks%';"
case_ "expiry job wrong schedule" smoke_readonly.sql S01 FAIL "update cron.job set schedule = '0 3 * * *' where command ilike '%aios_expire_stale_approvals%';"
case_ "expiry job never succeeded (reaper keeps running)" smoke_readonly.sql S02 FAIL "delete from cron.job_run_details where jobid in (select jobid from cron.job where command ilike '%aios_expire_stale_approvals%');"
case_ "recent failed run"         smoke_readonly.sql S03 FAIL "insert into cron.job_run_details (jobid, status, start_time) select jobid, 'failed', now() - interval '5 minutes' from cron.job limit 1;"

echo "== C. stale approvals (S05) incl. the NULL-expiry blind spot"
ins="insert into public.aios_approvals (organization_id, action, risk_level, status, created_at, expires_at) values (gen_random_uuid(), 'selftest', 'low', 'pending',"
case_ "lapsed 30 min ago"          smoke_readonly.sql S05 FAIL "$ins now() - interval '2 days', now() - interval '30 minutes');"
case_ "lapsed 3 min ago (grace)"   smoke_readonly.sql S05 PASS "$ins now() - interval '1 hour', now() - interval '3 minutes');"
case_ "no expiry, 3 days old"      smoke_readonly.sql S05 FAIL "$ins now() - interval '3 days', null);"
case_ "no expiry, 1 hour old"      smoke_readonly.sql S05 PASS "$ins now() - interval '1 hour', null);"
case_ "no expiry, old, owner-retained" smoke_readonly.sql S05 PASS "with a as (insert into public.aios_approvals (organization_id, action, risk_level, status, created_at, expires_at) values ('0a0a0a0a-0000-4000-8000-000000000001', 'selftest', 'low', 'pending', now() - interval '3 days', null) returning id, organization_id) insert into public.aios_backlog_dispositions (organization_id, entity_type, entity_id, classification, disposition, rationale) select organization_id, 'approval', id, 'owner_decision', 'owner_decision_retain', 'selftest' from a;"

echo "== D. triggers (S07-S10)"
case_ "approval trigger disabled"          smoke_readonly.sql S07 FAIL "alter table public.aios_approvals disable trigger trg_aios_approval_status_guard;"
case_ "approval trigger disabled -> S08"   smoke_readonly.sql S08 FAIL "alter table public.aios_approvals disable trigger trg_aios_approval_status_guard;"
case_ "trigger replica-only"               smoke_readonly.sql S07 FAIL "alter table public.aios_approvals enable replica trigger trg_aios_approval_status_guard;"
case_ "trigger replica-only -> S08"        smoke_readonly.sql S08 FAIL "alter table public.aios_approvals enable replica trigger trg_aios_approval_status_guard;"
case_ "audit UPDATE guard disabled"        smoke_readonly.sql S09 FAIL "alter table public.aios_audit_events disable trigger trg_aios_audit_immutable_update;"
case_ "audit DELETE guard disabled"        smoke_readonly.sql S10 FAIL "alter table public.aios_audit_events disable trigger trg_aios_audit_immutable_delete;"

echo "== E. proposal 001 / S11 (WARN -> PASS, never a silent half-state)"
case_ "guard absent -> WARN (known gap state)" smoke_readonly.sql S11 WARN "$noguard"
case_ "proposal 001 applied on a guard-less DB" smoke_readonly.sql S11 PASS "$noguard
$proposal"
case_ "proposal applied, TRUNCATE re-granted" smoke_readonly.sql S11 FAIL "$proposal
grant truncate on public.aios_audit_events to service_role;"
case_ "only the privilege revoked"         smoke_readonly.sql S11 FAIL "$noguard
revoke truncate on public.aios_audit_events from service_role;"
case_ "expected live but absent"           smoke_readonly.sql S11 FAIL "$noguard" replay 1
case_ "expected live and present"          smoke_readonly.sql S11 PASS "$proposal" replay 1

echo "== F. grants and definer hygiene (S12-S19, S23)"
case_ "RLS off"                            smoke_readonly.sql S12 FAIL "alter table public.aios_memory disable row level security;"
case_ "definer path unpinned"              smoke_readonly.sql S13 FAIL "alter function private.aios_expire_stale_approvals() reset all;"
case_ "anon can run a definer function"    smoke_readonly.sql S14 FAIL "grant execute on function private.aios_expire_stale_approvals() to anon;"
case_ "anon TRUNCATE in public"            smoke_readonly.sql S15 FAIL "grant truncate on public.aios_agents to anon;"
case_ "authenticated TRUNCATE on private"  smoke_readonly.sql S16 FAIL "grant truncate on private.aios_trusted_executors to authenticated;"
case_ "authenticated TRUNCATE on approvals" smoke_readonly.sql S17 FAIL "grant truncate on public.aios_approvals to authenticated;"
case_ "expiry function dropped (reported, not an error)" smoke_readonly.sql S18 FAIL "drop function private.aios_expire_stale_approvals();"
case_ "view no longer security_invoker"    smoke_readonly.sql S19 FAIL "alter view public.aios_backlog_effective_dispositions set (security_invoker = false);"
case_ "private fn granted to authenticated" smoke_readonly.sql S23 FAIL "grant execute on function private.aios_touch_task_updated_at() to authenticated;"
case_ "private fn granted to PUBLIC"       smoke_readonly.sql S23 FAIL "grant execute on function private.aios_touch_task_updated_at() to public;"
case_ "new private fn with default ACL (the original CI bug)" smoke_readonly.sql S23 FAIL "create function private.zz_selftest_default() returns int language sql as 'select 1';"

echo "== G. production-only state (S20)"
case_ "production profile without retain record" smoke_readonly.sql S20 FAIL "" production
case_ "replay profile does not fail on absent production data" smoke_readonly.sql S20 INFO "" replay

echo "== H. post-proposal verifier (P1-P6): missing objects are FAIL rows, not query errors"
case_ "before proposal 001: P2"            post_proposal_001_verify.sql P2 FAIL "$noguard"
case_ "before proposal 001: P4 (no function)" post_proposal_001_verify.sql P4 FAIL "$noguard"
for id in P1 P2 P3 P4 P5 P6; do case_ "after proposal 001" post_proposal_001_verify.sql $id PASS "$proposal"; done
case_ "guard trigger disabled"             post_proposal_001_verify.sql P2 FAIL "$proposal
alter table public.aios_audit_events disable trigger trg_aios_audit_no_truncate;"
case_ "guard function granted to PUBLIC"  post_proposal_001_verify.sql P4 FAIL "$proposal
grant execute on function private.aios_audit_no_truncate() to public;"

echo "== I. non-production TRUNCATE test fences"
g="$here/nonprod_truncate_guard_test.sql"
out="$(PGOPTIONS= psql "$DB" -X -q -t -f "$g" 2>&1)"; rc=$?
{ [ $rc -ne 0 ] && ! grep -q '^ok:' <<<"$out"; } && pass "refuses without smoke.nonprod=1 (exit $rc, no ok line)" || fail "ran without smoke.nonprod=1 (rc=$rc)"
trg_before="$(psqlq -c "select count(*) from pg_trigger where tgname = 'trg_aios_audit_no_truncate'")"
out="$(psqlq <<SQL 2>&1
begin;
set local smoke.nonprod = '1';
$noguard
\i $g
SQL
)"; rc=$?
{ [ $rc -ne 0 ] && ! grep -q '^ok:' <<<"$out"; } && pass "refuses when the guard trigger is absent, before any TRUNCATE (exit $rc, no ok line)" || fail "proceeded without the guard (rc=$rc)"
out="$(psqlq <<SQL 2>&1
begin;
set local smoke.nonprod = '1';
$proposal
\i $g
SQL
)"; rc=$?
{ [ $rc -eq 0 ] && grep -q '^ok:' <<<"$out"; } && pass "passes with guard present (exit 0, ok line)" || fail "did not pass with the guard present (rc=$rc): $(head -c 200 <<<"$out")"
[ "$(psqlq -c "select count(*) from pg_trigger where tgname = 'trg_aios_audit_no_truncate'")" = "$trg_before" ] && pass "guard state unchanged by the guard tests (nothing committed)" || fail "guard tests changed the committed trigger state"

echo "== J. runner: verdict logic, fail-closed behaviour, credentials"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ids="S00 S01 S02 S03 S04 S05 S06 S07 S08 S09 S10 S11 S12 S13 S14 S15 S16 S17 S18 S19 S20 S21 S22 S23"
mkrows() { local skip="${1:-}" force="${2:-}" id st; for id in $ids; do [ "$id" = "$skip" ] && continue; st=PASS; [ "$id" = S22 ] && st=WARN; [ "$id" = "${force%%=*}" ] && st="${force##*=}"; echo "$id name|$st|detail"; done; }
cat > "$tmp/psql" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SHIM_DIR/argv"; printf '%s\n' "${PGDATABASE:-}" > "$SHIM_DIR/pgdatabase"; printf '%s\n' "${PGOPTIONS:-}" > "$SHIM_DIR/pgoptions"
cat "$SHIM_DIR/rows"; exit "${SHIM_RC:-0}"
SHIM
chmod +x "$tmp/psql"
runner() { SHIM_DIR="$tmp" PATH="$tmp:$PATH" DATABASE_URL='postgresql://smoke_user:SuperSecret123@db.example:5432/postgres' bash "$here/run_smoke.sh" "$@" >"$tmp/out" 2>&1; echo $?; }
expect_rc() { local label="$1" want="$2" got="$3"; if [ "$got" = "$want" ]; then pass "runner: $label (exit $got)"; else fail "runner: $label expected exit $want, got $got"; tail -3 "$tmp/out"; fi; }

mkrows > "$tmp/rows";                               expect_rc "all rows present, WARN allowed" 0 "$(runner)"
mkrows "" S05=FAIL > "$tmp/rows";                   expect_rc "one FAIL row" 1 "$(runner)"
mkrows S12 > "$tmp/rows";                           expect_rc "missing row S12 (fail-open if rows were not counted)" 1 "$(runner)"
{ mkrows; echo "S05 dup|PASS|x"; } > "$tmp/rows";   expect_rc "duplicate row" 1 "$(runner)"
mkrows "" S06=MAYBE > "$tmp/rows";                  expect_rc "unknown status" 1 "$(runner)"
mkrows "" S00=WARN > "$tmp/rows";                   expect_rc "session not proven read-only (S00 WARN)" 1 "$(runner)"
{ mkrows; echo "S77 extra|PASS|x"; } > "$tmp/rows"; expect_rc "unexpected extra row" 1 "$(runner)"
mkrows > "$tmp/rows"; got="$(SHIM_RC=3 runner)"; if [ "$got" != 0 ]; then pass "runner: psql failure is never a pass (exit $got)"; else fail "runner: psql failure reported success"; fi
# SIGPIPE regression: a FAIL near the top of >1 MB of output. The old `echo "$out" | grep -q '|FAIL|'` exits early under pipefail
# and the `if` then reads the pipeline as "no FAIL". The runner must still report FAIL.
{ mkrows "" S01=FAIL; yes 'padding line to exceed the pipe buffer padding padding padding padding padding' | head -n 30000; } > "$tmp/rows"
expect_rc "FAIL row followed by >1 MB of output" 1 "$(runner)"
mkrows > "$tmp/rows"; runner >/dev/null
if grep -q 'SuperSecret123' "$tmp/argv"; then fail "runner: password appeared in psql argv"; else pass "runner: no credential in psql argv"; fi
[ "$(cat "$tmp/pgdatabase")" = 'postgresql://smoke_user:SuperSecret123@db.example:5432/postgres' ] && pass "runner: connection string passed via PGDATABASE" || fail "runner: connection string not passed via PGDATABASE"
grep -q 'default_transaction_read_only=on' "$tmp/pgoptions" && pass "runner: read-only session requested" || fail "runner: read-only not requested"
if grep -q 'SuperSecret123' "$tmp/out"; then fail "runner: password echoed in output"; else pass "runner: password not echoed"; fi
out="$(SHIM_DIR="$tmp" PATH="$tmp:$PATH" bash "$here/run_smoke.sh" 2>&1)"; rc=$?
[ $rc -eq 2 ] && pass "runner: refuses to run without credentials (exit 2)" || fail "runner: ran without credentials (rc=$rc)"

echo
if [ "$fails" -eq 0 ]; then echo "SMOKE SELFTEST: $total/$total PASS"; else echo "SMOKE SELFTEST: $fails of $total FAILED"; exit 1; fi
