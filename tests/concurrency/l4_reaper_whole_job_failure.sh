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
trap 'rc=$?; psql "$DB" -X -q -c "drop trigger if exists l4_wj_test_trg on public.aios_tasks; drop function if exists public.l4_wj_test_fn()" >/dev/null 2>&1; cron_restore || rc=1; exit $rc' EXIT
ORG=b4b4b4b4-0000-4000-8000-000000000001; AGT=b4b4b4b4-0000-4000-8000-000000000002
REQ=b4b4b4b4-0000-4000-8000-000000000003
q "insert into auth.users (id,aud,role,email) values ('$REQ','authenticated','authenticated','f2-req@example.test') on conflict do nothing;
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

echo "== fixture: four stale tasks on four independent missions"
read M1 T1 <<<"$(new_stale ok1)"; read M2 T2 <<<"$(new_stale bad1)"
read M3 T3 <<<"$(new_stale ok2)"; read M4 T4 <<<"$(new_stale retry)"
need_ids "$M1" "$T1" "$M2" "$T2" "$M3" "$T3" "$M4" "$T4"
[ "$(q "select count(*) from public.aios_tasks where id in ('$T1','$T2','$T3','$T4') and status='running' and updated_at<now()-interval '10 minutes'")" = 4 ] || { echo "fixture not stale"; exit 2; }

q "create or replace function public.l4_wj_test_fn() returns trigger language plpgsql as \$t\$
     begin
       if new.status='failed' and new.id='$T2' then raise exception 'forced invariant error' using errcode='XX001'; end if;
       if new.status='failed' and new.id='$T4' then raise exception 'forced transient lock conflict' using errcode='40P01'; end if;
       return new;
     end \$t\$;
     create trigger l4_wj_test_trg before update on public.aios_tasks for each row execute function public.l4_wj_test_fn();" >/dev/null

echo "== run 1: independent recoveries; T2 quarantined; T4 deferred"
R=$(q "select private.aios_reap_stale_tasks('10 minutes'::interval)::text") || { echo "reaper raised"; exit 1; }
check "T1 committed despite later record failure" "$([ "$(status "$T1")" = failed ] && echo true || echo false)"
check "T2 rolled back and remains running" "$([ "$(status "$T2")" = running ] && echo true || echo false)"
check "T2 received one manual-review disposition" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$T2' and disposition='manual_review'")" = 1 ] && echo true || echo false)"
check "T3 committed despite T4 lock conflict" "$([ "$(status "$T3")" = failed ] && echo true || echo false)"
check "T4 remains running after lock conflict" "$([ "$(status "$T4")" = running ] && echo true || echo false)"
check "T4 has durable retry state" "$([ "$(q "select count(*) from private.aios_task_reaper_deferred where task_id='$T4' and last_sqlstate='40P01'")" = 1 ] && echo true || echo false)"
check "T4 has no permanent disposition" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$T4'")" = 0 ] && echo true || echo false)"
check "return value reports deferred and quarantined records" "$([ "$(q "select ('$R'::jsonb->>'deferred')::int")" -ge 1 ] && [ "$(q "select ('$R'::jsonb->>'quarantined')::int")" -ge 1 ] && echo true || echo false)"

echo "== run 2: transient failure removed; retry is made eligible immediately"
q "drop trigger l4_wj_test_trg on public.aios_tasks;
   update private.aios_task_reaper_deferred set next_attempt_at=now() where task_id='$T4';" >/dev/null
R2=$(q "select private.aios_reap_stale_tasks('10 minutes'::interval)::text") || { echo "retry raised"; exit 1; }
check "T4 converged to failed on retry" "$([ "$(status "$T4")" = failed ] && echo true || echo false)"
check "successful retry cleared deferred state" "$([ "$(q "select count(*) from private.aios_task_reaper_deferred where task_id='$T4'")" = 0 ] && echo true || echo false)"
check "repeated run did not duplicate T1 disposition or recovery" "$([ "$(q "select count(*) from public.aios_tasks where id='$T1' and status='failed'")" = 1 ] && echo true || echo false)"
check "audit chain remains valid" "$([ "$(q "select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false); select (private.verify_audit_chain('$ORG'))->>'valid'" | tail -1)" = true ] && echo true || echo false)"
echo
echo "== F-2 per-record isolation: $([ "$fail" = 0 ] && echo ALL PASS || echo FAILURES)"
exit "$fail"
