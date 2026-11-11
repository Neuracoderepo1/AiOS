#!/usr/bin/env bash
# L4 reaper whole-job failure semantics (DETERMINISTIC, no timing): pins what aios_reap_stale_tasks() does when ONE record fails.
#
# DOCUMENTED BEHAVIOUR UNDER TEST (PR28 review, item 9). Unlike aios_expire_stale_approvals() the reaper has NO per-record sub-transaction:
#   * any error while processing any task (lock conflict 40P01/55P03/57014 OR a non-lock error) aborts the WHOLE job transaction;
#   * the job therefore commits NOTHING for that run (earlier tasks that were already reaped in the same run are rolled back, audit events included);
#   * the next cron tick (every 5 minutes) retries from scratch; there is no durable disposition and no deferral counter;
#   * CONSEQUENCE: one persistently failing task blocks reaping of ALL stale tasks until it is repaired (head-of-line blocking). Not redesigned here.
# This test fails if that behaviour silently changes (e.g. someone adds a handler that swallows errors) and proves the retry converges.
# Usage: l4_reaper_whole_job_failure.sh <conninfo>   (throwaway DB only)
set -u
DB="$1"; fail=0
q()  { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }
check() { if [ "$2" = "true" ]; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }
. "$(dirname "$0")/cron_guard.sh"
cron_pause "$DB" || { echo "cannot guarantee a quiet scheduler"; exit 1; }
trap 'rc=$?; psql "$DB" -X -q -c "drop trigger if exists l4_wj_test_trg on public.aios_tasks; drop function if exists public.l4_wj_test_fn()" >/dev/null 2>&1; cron_restore || rc=1; exit $rc' EXIT
ORG=a3a3a3a3-0000-4000-8000-000000000001; AGT=a3a3a3a3-0000-4000-8000-000000000002
REQ=a3a3a3a3-0000-4000-8000-000000000003
q "insert into auth.users (id,aud,role,email) values ('$REQ','authenticated','authenticated','alw-req@example.test') on conflict do nothing;
   insert into public.aios_organizations (id,name) values ('$ORG','alw-org') on conflict do nothing;
   insert into public.aios_organization_members (organization_id,user_id,role) values ('$ORG','$REQ','member') on conflict do nothing;
   insert into public.aios_agents (id,organization_id,agent_key,name,role,status,authority) values ('$AGT','$ORG','alw-agent','alw','alw','idle','{\"risk_level\":\"medium\",\"allowed_tools\":[\"support.export_customer_data\"],\"limits\":{}}') on conflict do nothing;" >/dev/null || { echo "fixture failed"; exit 2; }
need_ids() { for x in "$@"; do [[ "$x" =~ ^[0-9a-f-]{36}$ ]] || { echo "  FIXTURE FAILED (empty/invalid id): refusing to report any result"; exit 2; }; done; }

new_stale() { # <label> <age_minutes>: mission+task genuinely 'running' and stale (no invocation). Echoes "M T".
  local out; out=$(q "with m as (insert into public.aios_missions (organization_id,title,objective,status) values ('$ORG','alw-$1','alw','queued') returning id),
          t as (insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status) select '$ORG',id,'$AGT','alw-$1','queued' from m returning id,mission_id)
     select mission_id||' '||id from t" | tail -1)
  read M T <<<"$out"; need_ids "$M" "$T"
  q "update public.aios_missions set status='running' where id='$M'; update public.aios_tasks set status='running' where id='$T'" >/dev/null || { echo "  FIXTURE: cannot make task running"; exit 2; }
  q "begin; set local session_replication_role = replica; update public.aios_tasks set updated_at = now() - interval '$2 minutes' where id='$T'; commit;" >/dev/null
  echo "$M $T"
}
status() { q "select status from public.aios_tasks where id='$1'"; }
audits() { q "select count(*) from public.aios_audit_events where organization_id='$ORG'"; }

echo "== fixtures: two stale running tasks (T1 older => processed first; T2 second)"
read M1 T1 <<<"$(new_stale w1 60)"; read M2 T2 <<<"$(new_stale w2 50)"; need_ids "$M1" "$T1" "$M2" "$T2"
[ "$(q "select count(*) from public.aios_tasks where status='running' and updated_at < now() - interval '10 minutes'")" = 2 ] || { echo "FIXTURE: other stale tasks exist; run on a clean database"; exit 2; }

run_failing() { # <errcode> <label>
  q "create or replace function public.l4_wj_test_fn() returns trigger language plpgsql as \$t\$ begin
       if new.status = 'failed' and new.id = '$T2' then raise exception 'forced failure' using errcode = '$1'; end if; return new; end \$t\$;
     drop trigger if exists l4_wj_test_trg on public.aios_tasks;
     create trigger l4_wj_test_trg before update on public.aios_tasks for each row execute function public.l4_wj_test_fn();" >/dev/null
  local before; before=$(audits)
  local out rc; out=$(psql "$DB" -X -At -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -c "select private.aios_reap_stale_tasks('10 minutes'::interval)::text" 2>&1); rc=$?
  echo "  [$2] job rc=$rc; $(echo "$out" | grep -m1 -oE 'ERROR:[[:space:]]+[0-9A-Z]{5}' || echo 'no ERROR line')"
  check "[$2] the job raised (it did not swallow the error)" "$([ "$rc" != 0 ] && echo "$out" | grep -q "ERROR:  $1" && echo true || echo false)"
  check "[$2] T1 (reaped BEFORE the failure in the same run) was rolled back: still running" "$([ "$(status $T1)" = running ] && echo true || echo false)"
  check "[$2] T2 untouched: still running" "$([ "$(status $T2)" = running ] && echo true || echo false)"
  check "[$2] no audit event survived the failed run (whole transaction rolled back)" "$([ "$(audits)" = "$before" ] && echo true || echo false)"
  check "[$2] no disposition record written for either task" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id in ('$T1','$T2')")" = 0 ] && echo true || echo false)"
}
echo "== run 1: non-lock error (XX001) on T2"; run_failing XX001 non-lock
echo "== run 2: lock conflict (40P01) on T2 - the reaper does NOT defer, it aborts like any other error"; run_failing 40P01 lock-conflict
echo "== run 3: failure removed; the next run must converge"
q "drop trigger l4_wj_test_trg on public.aios_tasks" >/dev/null
R=$(q "select private.aios_reap_stale_tasks('10 minutes'::interval)::text") || { echo "  job raised"; exit 1; }
check "both tasks reaped on the retry (failed=2)" "$([ "$(q "select ('$R'::jsonb ->> 'failed')")" = 2 ] && [ "$(status $T1)" = failed ] && [ "$(status $T2)" = failed ] && echo true || echo false)"
check "audit chain still valid after the failed runs and the retry" "$([ "$(q "select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false); select (private.verify_audit_chain('$ORG'))->>'valid'" | tail -1)" = true ] && echo true || echo false)"
echo; echo "== L4 reaper whole-job failure: $([ $fail = 0 ] && echo ALL PASS || echo FAILURES)"; exit $fail
