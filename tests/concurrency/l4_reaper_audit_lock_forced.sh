#!/usr/bin/env bash
# L4 forced interleaving (DETERMINISTIC), stale-task reaper vs mission cancel: the exact cycle from the PostgreSQL deadlock graph, no timing luck.
#   cancel C : holds mission M2's row lock (as a mission cancel does) and is parked on a gate before its UPDATE (whose audit write needs the org audit lock)
#   expiry E : processes lapsed approvals A1 (earlier) then A2 (needs M2's chain)
# PRE-FIX : E writes audit for A1 (=> holds the org audit lock) and THEN waits for M2's row lock held by C; releasing C makes C wait for the audit lock => 40P01.
# POST-FIX: E locks every candidate's subtree (phase 1, no writes) BEFORE any audit write, so E waits holding NO audit lock; C proceeds and commits; E then finishes.
# Barriers are event based (pg_stat_activity lock waits + markers), never sleeps. Usage: l3_audit_lock_forced.sh <conninfo>   (throwaway DB only)
set -u
DB="$1"; fail=0; D=$(mktemp -d); EVID="${L3F_EVIDENCE_DIR:-/tmp/l3-forced-evidence}"; rm -rf "$EVID"; mkdir -p "$EVID"
q()  { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }
check() { if [ "$2" = "true" ]; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }
. "$(dirname "$0")/cron_guard.sh"
cron_pause "$DB" || { echo "cannot guarantee a quiet scheduler"; exit 1; }
trap 'rc=$?; exec 5>&- 2>/dev/null; kill $(jobs -p) 2>/dev/null; cp -r "$D"/. "$EVID"/ 2>/dev/null; rm -rf "$D"; cron_restore || rc=1; exit $rc' EXIT
ORG=a1a1a1a1-0000-4000-8000-000000000001; AGT=a1a1a1a1-0000-4000-8000-000000000002
REQ=a1a1a1a1-0000-4000-8000-000000000003; ADM=a1a1a1a1-0000-4000-8000-000000000004
q "insert into auth.users (id,aud,role,email) values ('$REQ','authenticated','authenticated','alo-req@example.test'),('$ADM','authenticated','authenticated','alo-adm@example.test') on conflict do nothing;
   insert into public.aios_organizations (id,name) values ('$ORG','alo-org') on conflict do nothing;
   insert into public.aios_organization_members (organization_id,user_id,role) values ('$ORG','$REQ','member'),('$ORG','$ADM','admin') on conflict do nothing;
   insert into public.aios_agents (id,organization_id,agent_key,name,role,status,authority) values ('$AGT','$ORG','alo-agent','alo','alo','idle','{\"risk_level\":\"medium\",\"allowed_tools\":[\"support.export_customer_data\"],\"limits\":{}}') on conflict do nothing;
   insert into public.aios_contracts (organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active) values ('$ORG','$AGT',1,'medium','[\"support.export_customer_data\"]','{}',true) on conflict (agent_id,version) do update set is_active=true;" >/dev/null || { echo "fixture failed"; exit 2; }

need_ids() { for x in "$@"; do [[ "$x" =~ ^[0-9a-f-]{36}$ ]] || { echo "  FIXTURE FAILED (empty/invalid id): refusing to report any result"; exit 2; }; done; }
as_service() { echo "set local role service_role; select set_config('request.jwt.claims','{\"role\":\"service_role\"}',true);"; }

# new_chain <label>: mission+task blocked_pending_approval, invocation requires_approval with a pending approval. Echoes "M T I A".
new_chain() {
  local out; out=$(q "with m as (insert into public.aios_missions (organization_id,title,objective,status) values ('$ORG','alo-$1','alo','queued') returning id),
          t as (insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status) select '$ORG',id,'$AGT','alo-$1','queued' from m returning id,mission_id),
          i as (insert into public.aios_tool_invocations (organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key)
                select '$ORG','$AGT',t.id,'support.export_customer_data','support.export_customer_data',jsonb_build_object('scope','$1','format','csv'),'low','$REQ',gen_random_uuid(),'alo-$1-'||gen_random_uuid() from t returning id,approval_id)
     select (select mission_id from t)||' '||(select id from t)||' '||(select id from i)||' '||coalesce((select approval_id::text from i),'x')" | tail -1)
  read M T I A <<<"$out"; need_ids "$M" "$T" "$I" "$A"
  q "update public.aios_missions set status='running' where id='$M'; update public.aios_tasks set status='running' where id='$T'; update public.aios_tasks set status='blocked_pending_approval' where id='$T'; update public.aios_missions set status='blocked_pending_approval' where id='$M';" >/dev/null || { echo "  chain transition failed"; exit 2; }
  [ "$(q "select status from public.aios_tool_invocations where id='$I'")" = requires_approval ] || { echo "  FIXTURE: invocation is not requires_approval"; exit 2; }
  echo "$M $T $I $A"
}


new_stale() { # <label> <age_minutes>: mission+task genuinely 'running' and stale (no invocation). Echoes "M T".
  local out; out=$(q "with m as (insert into public.aios_missions (organization_id,title,objective,status) values ('$ORG','alo-$1','alo','queued') returning id),
          t as (insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status) select '$ORG',id,'$AGT','alo-$1','queued' from m returning id,mission_id)
     select mission_id||' '||id from t" | tail -1)
  read M T <<<"$out"; need_ids "$M" "$T"
  q "update public.aios_missions set status='running' where id='$M'; update public.aios_tasks set status='running' where id='$T'" >/dev/null || { echo "  FIXTURE: cannot make task running"; exit 2; }
  q "begin; set local session_replication_role = replica; update public.aios_tasks set updated_at = now() - interval '$2 minutes' where id='$T'; commit;" >/dev/null
  echo "$M $T"
}
echo "== fixtures: two stale running tasks (T1 older than T2), each on its own mission"
read M1 T1 <<<"$(new_stale r1 60)"; read M2 T2 <<<"$(new_stale r2 50)"; need_ids "$M1" "$T1" "$M2" "$T2"
[ "$(q "select count(*) from public.aios_tasks where id in ('$T1','$T2') and status='running' and updated_at < now() - interval '10 minutes'")" = 2 ] || { echo "FIXTURE: tasks not stale+running"; exit 2; }
# other stale tasks from earlier runs would be processed by E as well; this suite needs a clean candidate set
[ "$(q "select count(*) from public.aios_tasks where status='running' and updated_at < now() - interval '10 minutes'")" = 2 ] || { echo "FIXTURE: other stale tasks exist; run on a clean database"; exit 2; }

G=941999
exec 5> >(psql "$DB" -X -At -q > "$D/gate.out" 2>&1); printf 'select pg_advisory_lock(%s);\nselect %s;\n' $G "'GATE_HELD'" >&5
i=0; until grep -q GATE_HELD "$D/gate.out" 2>/dev/null; do i=$((i+1)); [ $i -gt 400 ] && { echo "gate never held"; exit 2; }; sleep 0.05; done

echo "== C: cancel session takes mission M2's row lock, then parks on the gate"
( printf "begin;\nselect 'C_HAS_ROW' from public.aios_missions where id='$M2' for no key update;\nselect pg_advisory_lock_shared($G);\nselect pg_advisory_unlock_shared($G);\nupdate public.aios_missions set status='cancelled' where id='$M2';\ncommit;\nselect 'C_DONE';\n" \
  | psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose > "$D/c.out" 2> "$D/c.err"; echo $? > "$D/c.rc" ) &
i=0; until grep -q C_HAS_ROW "$D/c.out" 2>/dev/null; do i=$((i+1)); [ $i -gt 400 ] && { echo "C never obtained the row lock"; exit 2; }; sleep 0.05; done
i=0; until [ "$(q "select count(*) from pg_locks where locktype='advisory' and not granted and objid=$G")" = 1 ]; do i=$((i+1)); [ $i -gt 400 ] && { echo "C never parked"; exit 2; }; sleep 0.05; done
echo "  barrier: C holds M2's row lock and is parked on the gate"

echo "== E: expiry job starts and must end up WAITING for M2's row lock"
( psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -c "select 'E_RESULT ' || private.aios_reap_stale_tasks('10 minutes'::interval)::text" > "$D/e.out" 2> "$D/e.err"; echo $? > "$D/e.rc" ) &
i=0; until [ "$(q "select count(*) from pg_stat_activity where wait_event_type='Lock' and wait_event='transactionid' and query like '%aios_reap_stale_tasks%' and pid<>pg_backend_pid()")" = 1 ]; do i=$((i+1)); [ $i -gt 600 ] && { echo "E never blocked on the row lock"; exit 2; }; sleep 0.05; done
HELD=$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid=l.pid where l.locktype='advisory' and l.granted and a.query like '%aios_reap_stale_tasks%'")
echo "  barrier: E is blocked on a row lock held by C; E holds the org AUDIT advisory lock: $([ "$HELD" -ge 1 ] && echo YES || echo NO)"
echo "$HELD" > "$D/e_holds_audit_lock_while_waiting"

echo "== release C (its UPDATE needs the org audit lock)"
printf 'select pg_advisory_unlock(%s);\n' $G >&5
i=0; until [ -f "$D/c.rc" ] && [ -f "$D/e.rc" ]; do i=$((i+1)); [ $i -gt 700 ] && { echo "  workers did not finish (hang)"; fail=1; break; }; sleep 0.05; done
exec 5>&-; wait 2>/dev/null
DEAD=$(cat "$D"/c.err "$D"/c.out "$D"/e.err "$D"/e.out 2>/dev/null | grep -cE '40P01|deadlock detected')
echo "  C rc=$(cat "$D/c.rc" 2>/dev/null) E rc=$(cat "$D/e.rc" 2>/dev/null) deadlocks=$DEAD E_holds_audit_lock_while_waiting_for_a_row=$HELD"
check "E did not hold the org audit advisory lock while waiting for a row lock (the inversion precondition)" "$([ "$HELD" = 0 ] && echo true || echo false)"
check "no deadlock (40P01)" "$([ "$DEAD" = 0 ] && echo true || echo false)"
check "the mission cancellation committed (cancel never loses)" "$([ "$(q "select status from public.aios_missions where id='$M2'")" = cancelled ] && [ "$(cat "$D/c.rc")" = 0 ] && echo true || echo false)"
check "the expiry job finished successfully" "$([ "$(cat "$D/e.rc")" = 0 ] && grep -q E_RESULT "$D/e.out" && echo true || echo false)"
check "reconciliation: reaper failed T1; M2 cancelled (cancel never loses)" "$([ "$(q "select status from public.aios_tasks where id='$T1'")" = failed ] && [ "$(q "select status from public.aios_missions where id='$M2'")" = cancelled ] && echo true || echo false)"
echo; echo "== L4 forced interleaving (reaper): $([ $fail = 0 ] && echo ALL PASS || echo FAILURES)"; exit $fail
