#!/usr/bin/env bash
# F-2: deterministic per-record stale-task recovery semantics on throwaway PostgreSQL.
# A failing task must not roll back an earlier successful recovery. Lock conflicts defer;
# non-lock transition failures quarantine without mutating the task.
set -u
DB="$1"; fail=0
q() { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }
check() { if [ "$2" = "true" ]; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }
. "$(dirname "$0")/cron_guard.sh"
cron_pause "$DB" || { echo "cannot guarantee a quiet scheduler"; exit 1; }
# Every invocation receives fresh identities, isolating all three CI repetitions.
ORG="$(q "select gen_random_uuid()")"; AGT="$(q "select gen_random_uuid()")"
REQ="$(q "select gen_random_uuid()")"
ORG2="$(q "select gen_random_uuid()")"; AGT2="$(q "select gen_random_uuid()")"
LOCK_PID=""; LOCK_LOG=""
AUTH_LOCK_PID=""; AUTH_LOCK_LOG=""
AUTH_RESOLVER_PID=""; AUTH_RESOLVER_LOG=""
verify_chain() {
  q "select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false); select (private.verify_audit_chain('$1'))->>'valid'" | tail -1
}
cleanup() {
  rc=$?
  trap - EXIT
  if [ -n "$LOCK_PID" ]; then kill "$LOCK_PID" 2>/dev/null || true; wait "$LOCK_PID" 2>/dev/null || true; fi
  if [ -n "$AUTH_LOCK_PID" ]; then kill "$AUTH_LOCK_PID" 2>/dev/null || true; wait "$AUTH_LOCK_PID" 2>/dev/null || true; fi
  if [ -n "$AUTH_RESOLVER_PID" ]; then kill "$AUTH_RESOLVER_PID" 2>/dev/null || true; wait "$AUTH_RESOLVER_PID" 2>/dev/null || true; fi
  [ -z "$LOCK_LOG" ] || rm -f "$LOCK_LOG"
  [ -z "$AUTH_LOCK_LOG" ] || rm -f "$AUTH_LOCK_LOG"
  [ -z "$AUTH_RESOLVER_LOG" ] || rm -f "$AUTH_RESOLVER_LOG"
  # Throwaway CI database only: remove the complete fixture, including audit evidence.
  psql "$DB" -X -q -v ON_ERROR_STOP=1 >/dev/null <<SQL || rc=1
begin;
set local session_replication_role=replica;
-- The audit DELETE guard is ENABLE ALWAYS, so replication_role alone cannot bypass it.
-- This is a disposable CI database: temporarily disable only that guard for fixture cleanup,
-- then restore its ALWAYS state before committing the cleanup transaction.
alter table public.aios_audit_events disable trigger trg_aios_audit_immutable_delete;
drop trigger if exists l4_wj_test_trg on public.aios_tasks;
drop function if exists public.l4_wj_test_fn();
delete from public.aios_backlog_dispositions where organization_id in ('$ORG','$ORG2');
delete from public.aios_audit_events where organization_id in ('$ORG','$ORG2');
alter table public.aios_audit_events enable always trigger trg_aios_audit_immutable_delete;
delete from private.aios_task_reaper_deferred where task_id in (select id from public.aios_tasks where organization_id in ('$ORG','$ORG2'));
delete from private.aios_task_reaper_quarantine where task_id in (select id from public.aios_tasks where organization_id in ('$ORG','$ORG2'));
delete from public.aios_tasks where organization_id in ('$ORG','$ORG2');
delete from public.aios_missions where organization_id in ('$ORG','$ORG2');
delete from public.aios_agents where organization_id in ('$ORG','$ORG2');
delete from public.aios_organization_members where organization_id in ('$ORG','$ORG2');
delete from public.aios_organizations where id in ('$ORG','$ORG2');
delete from auth.users where id='$REQ';
commit;
SQL
  cron_restore || rc=1
  exit "$rc"
}
trap cleanup EXIT
q "insert into auth.users (id,aud,role,email) values ('$REQ','authenticated','authenticated','f2-$REQ@example.test') on conflict do nothing;
   insert into public.aios_organizations (id,name) values ('$ORG','f2-org') on conflict do nothing;
   insert into public.aios_organization_members (organization_id,user_id,role) values ('$ORG','$REQ','member') on conflict do nothing;
   insert into public.aios_agents (id,organization_id,agent_key,name,role,status,authority) values ('$AGT','$ORG','f2-agent','f2','f2','idle','{\"risk_level\":\"medium\",\"allowed_tools\":[\"support.export_customer_data\"],\"limits\":{}}') on conflict do nothing;" >/dev/null || { echo "fixture failed"; exit 2; }
need_ids() { for x in "$@"; do [[ "$x" =~ ^[0-9a-f-]{36}$ ]] || { echo "FIXTURE FAILED: invalid id"; exit 2; }; done; }
new_stale() {
  local out M T
  out=$(q "with m as (insert into public.aios_missions (organization_id,title,objective,status) values ('$ORG','f2-$1','f2','queued') returning id),
    t as (insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status) select '$ORG',id,'$AGT','f2-$1','queued' from m returning id,mission_id)
    select mission_id||' '||id from t" | tail -1)
  read M T <<<"$out"; need_ids "$M" "$T"
  q "update public.aios_missions set status='running' where id='$M'; update public.aios_tasks set status='running' where id='$T';
     begin; set local session_replication_role=replica; update public.aios_tasks set updated_at=now()-interval '60 minutes' where id='$T'; commit;" >/dev/null
  echo "$M $T"
}
status() { q "select status from public.aios_tasks where id='$1'"; }
audits() { q "select count(*) from public.aios_audit_events where organization_id='$ORG'"; }

echo "== fixture: five stale tasks on five independent missions"
read M1 T1 <<<"$(new_stale ok1)"; read M2 T2 <<<"$(new_stale bad1)"
read M3 T3 <<<"$(new_stale ok2)"; read M4 T4 <<<"$(new_stale retry)"
read M5 T5 <<<"$(new_stale suppressed-update)"
need_ids "$M1" "$T1" "$M2" "$T2" "$M3" "$T3" "$M4" "$T4" "$M5" "$T5"
[ "$(q "select count(*) from public.aios_tasks where id in ('$T1','$T2','$T3','$T4','$T5') and status='running' and updated_at<now()-interval '10 minutes'")" = 5 ] || { echo "fixture not stale"; exit 2; }

q "create or replace function public.l4_wj_test_fn() returns trigger language plpgsql as \$t\$
     begin
       if new.status='failed' and new.id='$T2' then raise exception 'forced invariant error' using errcode='XX001'; end if;
       if new.status='failed' and new.id='$T4' then raise exception 'forced transient lock conflict' using errcode='40P01'; end if;
       if new.status='failed' and new.id='$T5' then return null; end if;
       return new;
     end \$t\$;
     create trigger l4_wj_test_trg before update on public.aios_tasks for each row execute function public.l4_wj_test_fn();" >/dev/null

echo "== run 1: independent recoveries; T2 quarantined; T4 deferred"
check "audit chain valid before run 1" "$( [ "$(verify_chain "$ORG")" = true ] && echo true || echo false)"
R=$(q "select private.aios_reap_stale_tasks('10 minutes'::interval)::text") || { echo "reaper raised"; exit 1; }
check "T1 committed despite later record failure" "$([ "$(status "$T1")" = failed ] && echo true || echo false)"
check "T2 rolled back and remains running" "$([ "$(status "$T2")" = running ] && echo true || echo false)"
check "T2 received one manual-review disposition" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$T2' and disposition='manual_review'")" = 1 ] && echo true || echo false)"
check "T3 committed despite T4 lock conflict" "$([ "$(status "$T3")" = failed ] && echo true || echo false)"
check "T4 remains running after lock conflict" "$([ "$(status "$T4")" = running ] && echo true || echo false)"
check "T4 has durable retry state" "$([ "$(q "select count(*) from private.aios_task_reaper_deferred where task_id='$T4' and last_sqlstate='40P01'")" = 1 ] && echo true || echo false)"
check "T4 has no permanent disposition" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$T4'")" = 0 ] && echo true || echo false)"
check "T5 remains running when a BEFORE UPDATE trigger suppresses its transition" "$([ "$(status "$T5")" = running ] && echo true || echo false)"
check "suppressed T5 transition is quarantined with P0002" "$([ "$(q "select count(*) from private.aios_task_reaper_quarantine where task_id='$T5' and resolved_at is null and sqlstate='P0002'")" = 1 ] && echo true || echo false)"
check "suppressed T5 transition receives one manual-review disposition" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$T5' and disposition='manual_review'")" = 1 ] && echo true || echo false)"
check "return value reports deferred and quarantined records" "$([ "$(q "select ('$R'::jsonb->>'deferred')::int")" -ge 1 ] && [ "$(q "select ('$R'::jsonb->>'quarantined')::int")" -ge 1 ] && echo true || echo false)"
check "audit chain valid after run 1" "$( [ "$(verify_chain "$ORG")" = true ] && echo true || echo false)"


echo "== run 1b: unresolved quarantine is excluded from the next reaper run"
check "audit chain valid before quarantine repeat" "$( [ "$(verify_chain "$ORG")" = true ] && echo true || echo false)"
DISPOSITION_BEFORE=$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$T2' and disposition='manual_review'")
AUDIT_BEFORE=$(audits)
R1B=$(q "select private.aios_reap_stale_tasks('10 minutes'::interval)::text") || { echo "quarantine repeat raised"; exit 1; }
check "quarantined T2 remains untouched on repeat run" "$([ "$(status "$T2")" = running ] && echo true || echo false)"
check "quarantine marker remains active" "$([ "$(q "select count(*) from private.aios_task_reaper_quarantine where task_id='$T2' and resolved_at is null")" = 1 ] && echo true || echo false)"
check "repeat run does not duplicate T2 disposition" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$T2' and disposition='manual_review'")" = "$DISPOSITION_BEFORE" ] && echo true || echo false)"
check "repeat run produces no T2 audit transition" "$([ "$(audits)" = "$AUDIT_BEFORE" ] && echo true || echo false)"
check "audit chain valid after quarantine repeat" "$( [ "$(verify_chain "$ORG")" = true ] && echo true || echo false)"

echo "== owner resolution: ordinary member is denied"
q "update public.aios_organization_members set role='member' where organization_id='$ORG' and user_id='$REQ';" >/dev/null
MEMBER_DENIAL=$(psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "select set_config('request.jwt.claim.sub','$REQ',false); select set_config('request.jwt.claims','{\"sub\":\"$REQ\",\"role\":\"authenticated\"}',false); select public.aios_resolve_task_reaper_quarantine('$T2','Member must not release an owner quarantine.');" 2>&1)
MEMBER_RC=$?
check "ordinary member cannot resolve quarantine" "$([ "$MEMBER_RC" -ne 0 ] && echo "$MEMBER_DENIAL" | grep -q 'organization owner/admin authorization required' && echo true || echo false)"

echo "== owner-only RPC privilege boundary: only authenticated may execute (no PUBLIC / anon / service_role)"
# The function body authorizes by auth.uid(), which any session can set through request.jwt.claim.sub. The EXECUTE grant is the
# only barrier that stops a service-side role from presenting an owner identity, so it is asserted directly and with real roles.
RPC='public.aios_resolve_task_reaper_quarantine(uuid,text)'
check "authenticated can execute the owner resolution RPC" "$([ "$(q "select has_function_privilege('authenticated','$RPC','execute')")" = t ] && echo true || echo false)"
check "anon cannot execute the owner resolution RPC" "$([ "$(q "select has_function_privilege('anon','$RPC','execute')")" = f ] && echo true || echo false)"
check "service_role cannot execute the owner resolution RPC" "$([ "$(q "select has_function_privilege('service_role','$RPC','execute')")" = f ] && echo true || echo false)"
check "PUBLIC holds no EXECUTE on the owner resolution RPC" "$([ "$(q "select count(*) from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where p.oid='$RPC'::regprocedure and a.grantee=0 and a.privilege_type='EXECUTE'")" = 0 ] && echo true || echo false)"
# Real calls with a spoofed owner identity against a task id that does not exist: a correct ACL refuses before the body runs
# ('permission denied for function'); a wrong ACL reaches the body ('task not found') and never mutates quarantine state.
for ROLE in anon service_role; do
  ROLE_OUT=$(psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "begin; set local role $ROLE; select set_config('request.jwt.claim.sub','$REQ',true); select set_config('request.jwt.claims','{\"sub\":\"$REQ\",\"role\":\"$ROLE\"}',true); select public.aios_resolve_task_reaper_quarantine('b4b4b4b4-0000-4000-8000-0000000000ff','Role must not reach the function body.'); rollback;" 2>&1)
  ROLE_RC=$?
  check "$ROLE with a spoofed owner identity is refused before the function body runs" "$([ "$ROLE_RC" -ne 0 ] && echo "$ROLE_OUT" | grep -q 'permission denied for function' && echo true || echo false)"
done

echo "== authorization race: committed owner demotion wins before quarantine resolution"
q "update public.aios_organization_members set role='owner' where organization_id='$ORG' and user_id='$REQ';" >/dev/null
AUTH_LOCK_LOG=$(mktemp)
(
  psql "$DB" -X -At -q -v ON_ERROR_STOP=1 >"$AUTH_LOCK_LOG" 2>&1 <<SQL
begin;
update public.aios_organization_members set role='member'
where organization_id='$ORG' and user_id='$REQ';
select 'F2_MEMBER_DEMOTION_HELD';
select pg_sleep(12);
commit;
SQL
) &
AUTH_LOCK_PID=$!
i=0
until grep -q F2_MEMBER_DEMOTION_HELD "$AUTH_LOCK_LOG" 2>/dev/null; do
  i=$((i+1)); [ "$i" -gt 200 ] && { echo "membership demotion never reached barrier"; exit 2; }
  sleep 0.05
done
AUTH_RESOLVER_LOG=$(mktemp)
(
  PGAPPNAME=f2-membership-race-resolver psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "select set_config('request.jwt.claim.sub','$REQ',false); select set_config('request.jwt.claims','{\"sub\":\"$REQ\",\"role\":\"authenticated\"}',false); select public.aios_resolve_task_reaper_quarantine('$T2','Concurrent demotion must prevent owner quarantine release.');" >"$AUTH_RESOLVER_LOG" 2>&1
) &
AUTH_RESOLVER_PID=$!
i=0; AUTH_WAITING=0
while [ "$i" -lt 200 ]; do
  AUTH_WAITING=$(q "select count(*) from pg_stat_activity where application_name='f2-membership-race-resolver' and state='active' and wait_event_type='Lock'")
  [ "$AUTH_WAITING" = 1 ] && break
  if ! kill -0 "$AUTH_RESOLVER_PID" 2>/dev/null; then break; fi
  i=$((i+1)); sleep 0.05
done
check "resolver blocks on the membership row while demotion holds it" "$([ "$AUTH_WAITING" = 1 ] && echo true || echo false)"
wait "$AUTH_LOCK_PID" || { echo "membership demotion transaction failed"; exit 2; }
AUTH_LOCK_PID=""
wait "$AUTH_RESOLVER_PID"; AUTH_RESOLVER_RC=$?
AUTH_RESOLVER_PID=""
check "resolver is denied after the committed owner demotion" "$([ "$AUTH_RESOLVER_RC" -ne 0 ] && grep -q 'organization owner/admin authorization required' "$AUTH_RESOLVER_LOG" && echo true || echo false)"
check "denied race leaves quarantine active and unresolved" "$([ "$(q "select count(*) from private.aios_task_reaper_quarantine where task_id='$T2' and resolved_at is null")" = 1 ] && echo true || echo false)"
check "denied race creates no owner-decision disposition" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$T2' and classification='owner_decision'")" = 0 ] && echo true || echo false)"
rm -f "$AUTH_LOCK_LOG" "$AUTH_RESOLVER_LOG"; AUTH_LOCK_LOG=""; AUTH_RESOLVER_LOG=""
q "update public.aios_organization_members set role='owner' where organization_id='$ORG' and user_id='$REQ';" >/dev/null

echo "== owner resolution: authorized org owner releases quarantine"
q "select set_config('request.jwt.claim.sub','$REQ',false);
   select set_config('request.jwt.claims','{\"sub\":\"$REQ\",\"role\":\"authenticated\"}',false);
   select public.aios_resolve_task_reaper_quarantine('$T2','Owner inspected the invariant failure and approved reprocessing.');" >/dev/null
check "owner resolution is durably recorded" "$([ "$(q "select count(*) from private.aios_task_reaper_quarantine where task_id='$T2' and resolved_at is not null and resolved_by='$REQ' and length(resolution_note)>=12")" = 1 ] && echo true || echo false)"
check "owner decision is present in append-only history" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$T2' and classification='owner_decision' and disposition='owner_decision_retain'")" = 1 ] && echo true || echo false)"

echo "== run 2: transient failure removed; retry is made eligible immediately"
check "audit chain valid before run 2 retry" "$( [ "$(verify_chain "$ORG")" = true ] && echo true || echo false)"
q "drop trigger l4_wj_test_trg on public.aios_tasks;
   update private.aios_task_reaper_deferred set next_attempt_at=now() where task_id='$T4';" >/dev/null
R2=$(q "select private.aios_reap_stale_tasks('10 minutes'::interval)::text") || { echo "retry raised"; exit 1; }
check "T4 converged to failed on retry" "$([ "$(status "$T4")" = failed ] && echo true || echo false)"
check "owner-released T2 becomes eligible and converges after invariant is repaired" "$([ "$(status "$T2")" = failed ] && [ "$(q "select count(*) from private.aios_task_reaper_quarantine where task_id='$T2' and resolved_at is not null")" = 1 ] && echo true || echo false)"
check "successful retry cleared deferred state" "$([ "$(q "select count(*) from private.aios_task_reaper_deferred where task_id='$T4'")" = 0 ] && echo true || echo false)"
check "repeated run did not duplicate T1 disposition or recovery" "$([ "$(q "select count(*) from public.aios_tasks where id='$T1' and status='failed'")" = 1 ] && echo true || echo false)"
check "audit chain valid after run 2 retry" "$( [ "$(verify_chain "$ORG")" = true ] && echo true || echo false)"
echo "== run 3: one organization audit lock is held; another organization must still recover"
q "insert into public.aios_organizations (id,name) values ('$ORG2','f2-org-independent') on conflict do nothing;
   insert into public.aios_organization_members (organization_id,user_id,role) values ('$ORG2','$REQ','member') on conflict do nothing;
   insert into public.aios_agents (id,organization_id,agent_key,name,role,status,authority)
     values ('$AGT2','$ORG2','f2-agent-independent','f2-independent','f2','idle','{\"risk_level\":\"medium\",\"allowed_tools\":[\"support.export_customer_data\"],\"limits\":{}}') on conflict do nothing;" >/dev/null || { echo "second-org fixture failed"; exit 2; }
OUT=$(q "with m as (
  insert into public.aios_missions (organization_id,title,objective,status)
  values ('$ORG2','f2-independent','f2','queued') returning id
), t as (
  insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status)
  select '$ORG2',id,'$AGT2','f2-independent','queued' from m returning id,mission_id
)
select mission_id||' '||id from t" | tail -1)
read M5 T5 <<<"$OUT"; need_ids "$M5" "$T5"
q "update public.aios_missions set status='running' where id='$M5';
   update public.aios_tasks set status='running' where id='$T5';
   begin; set local session_replication_role=replica;
   update public.aios_tasks set updated_at=now()-interval '60 minutes' where id='$T5'; commit;" >/dev/null
# Add a fresh organization-1 candidate dedicated to the cross-organization lock test.
read M6 T6 <<<"$(new_stale auditlock-1 60)"
read M7 T7 <<<"$(new_stale auditlock-2 60)"
need_ids "$M6" "$T6" "$M7" "$T7"
ORG_AUDIT_BEFORE=$(q "select count(*) from public.aios_audit_events where organization_id='$ORG'")
ORG_DISPOSITION_BEFORE=$(q "select count(*) from public.aios_backlog_dispositions where organization_id='$ORG'")
check "organization A audit chain valid before run 3" "$( [ "$(verify_chain "$ORG")" = true ] && echo true || echo false)"
check "organization B audit chain valid before run 3" "$( [ "$(verify_chain "$ORG2")" = true ] && echo true || echo false)"
LOCK_LOG=$(mktemp)
(
  psql "$DB" -X -At -q -v ON_ERROR_STOP=1 >"$LOCK_LOG" 2>&1 <<SQL
begin;
select pg_advisory_xact_lock(hashtextextended('$ORG',0));
select 'F2_ORG_AUDIT_LOCK_HELD';
select pg_sleep(20);
commit;
SQL
) &
LOCK_PID=$!
i=0
until grep -q F2_ORG_AUDIT_LOCK_HELD "$LOCK_LOG" 2>/dev/null; do
  i=$((i+1)); [ "$i" -gt 400 ] && { echo "audit lock holder never reached barrier"; kill "$LOCK_PID" 2>/dev/null || true; exit 2; }
  sleep 0.05
done
echo "  barrier: organization $ORG audit advisory lock is held"
START=$(date +%s)
R3=$(q "select private.aios_reap_stale_tasks('10 minutes'::interval)::text") || { echo "reaper failed during cross-org contention"; wait "$LOCK_PID" || true; exit 1; }
ELAPSED=$(( $(date +%s) - START ))
ORG_AUDIT_AFTER=$(q "select count(*) from public.aios_audit_events where organization_id='$ORG'")
ORG_DISPOSITION_AFTER=$(q "select count(*) from public.aios_backlog_dispositions where organization_id='$ORG'")
check "reaper returns without waiting for the contended organization lock (<5s; elapsed=${ELAPSED}s)" "$([ "$ELAPSED" -lt 5 ] && echo true || echo false)"
check "every candidate in contended organization remains untouched" "$([ "$(status "$T6")" = running ] && [ "$(status "$T7")" = running ] && [ "$(q "select status from public.aios_missions where id='$M6'")" = running ] && [ "$(q "select status from public.aios_missions where id='$M7'")" = running ] && echo true || echo false)"
check "every contended-org candidate is deferred with its own 55P03 diagnostic" "$([ "$(q "select count(*) from private.aios_task_reaper_deferred where task_id in ('$T6','$T7') and last_sqlstate='55P03' and last_error like '%pg_try_advisory_xact_lock returned false%'")" = 2 ] && echo true || echo false)"
check "no public audit event was appended for contended organization" "$([ "$ORG_AUDIT_BEFORE" = "$ORG_AUDIT_AFTER" ] && echo true || echo false)"
check "no public quarantine/disposition was appended for contended organization" "$([ "$ORG_DISPOSITION_BEFORE" = "$ORG_DISPOSITION_AFTER" ] && echo true || echo false)"
check "unrelated organization task recovered while first org lock remains held" "$([ "$(status "$T5")" = failed ] && echo true || echo false)"
check "unrelated organization mission reached terminal failed state" "$([ "$(q "select status from public.aios_missions where id='$M5'")" = failed ] && echo true || echo false)"
wait "$LOCK_PID" || { echo "audit lock holder failed"; fail=1; }
rm -f "$LOCK_LOG"; LOCK_LOG=""; LOCK_PID=""
check "organization A audit chain valid after run 3" "$( [ "$(verify_chain "$ORG")" = true ] && echo true || echo false)"
check "organization B audit chain valid after run 3" "$( [ "$(verify_chain "$ORG2")" = true ] && echo true || echo false)"

echo
# Remove the test-only owner-decision fixture so later production-profile smoke checks
# cannot mistake this throwaway task's owner decision for production evidence.
q "begin; set local session_replication_role=replica;
   delete from public.aios_backlog_dispositions where entity_id='$T2' and classification='owner_decision';
   commit;" >/dev/null
check "test-only owner-decision fixture cleaned up" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$T2' and classification='owner_decision'")" = 0 ] && echo true || echo false)"

echo "== F-2 per-record isolation: $([ "$fail" = 0 ] && echo ALL PASS || echo FAILURES)"
exit "$fail"
