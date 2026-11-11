#!/usr/bin/env bash
# Real-PostgreSQL regression: reverse-linked approvals must join the same global mission order
# as stale-task reaper pre-locking. Exercises both batch helpers concurrently while both are
# blocked on the first mission row. It also verifies no org audit advisory lock is held while
# either pre-lock worker waits for that row. Throwaway CI database only.
set -euo pipefail
DB="$1"
D=$(mktemp -d)
fail=0
q() { psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -c "$1"; }
check() { if [ "$2" = true ]; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }
. "$(dirname "$0")/cron_guard.sh"
cron_pause "$DB" || { echo "cannot guarantee a quiet scheduler"; exit 1; }
cleanup() {
  rc=$?
  [ -n "${BLOCK_PID:-}" ] && kill "$BLOCK_PID" 2>/dev/null || true
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  [ -n "${TASK_PID:-}" ] && kill "$TASK_PID" 2>/dev/null || true
  cron_restore || rc=1
  rm -rf "$D"
  exit "$rc"
}
trap cleanup EXIT

ORG=ab010101-0000-4000-8000-000000000001
AGT=ab010101-0000-4000-8000-000000000002
REQ=ab010101-0000-4000-8000-000000000003
ADM=ab010101-0000-4000-8000-000000000004
q "insert into auth.users (id,aud,role,email) values ('$REQ','authenticated','authenticated','rev-req@example.test'),('$ADM','authenticated','authenticated','rev-adm@example.test') on conflict do nothing;
   insert into public.aios_organizations (id,name) values ('$ORG','reverse-link-order') on conflict do nothing;
   insert into public.aios_organization_members (organization_id,user_id,role) values ('$ORG','$REQ','member'),('$ORG','$ADM','admin') on conflict do nothing;
   insert into public.aios_agents (id,organization_id,agent_key,name,role,status,authority) values ('$AGT','$ORG','reverse-link-agent','reverse-link','reverse-link','idle','{\"risk_level\":\"medium\",\"allowed_tools\":[\"support.export_customer_data\"],\"limits\":{}}') on conflict do nothing;
   insert into public.aios_contracts (organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active) values ('$ORG','$AGT',1,'medium','[\"support.export_customer_data\"]','{}',true) on conflict (agent_id,version) do update set is_active=true;" >/dev/null

need_id() { [[ "$1" =~ ^[0-9a-f-]{36}$ ]] || { echo "fixture failed: invalid id '$1'"; exit 2; }; }
new_chain() {
  local out M T I A
  out=$(q "with m as (
      insert into public.aios_missions (organization_id,title,objective,status)
      values ('$ORG','reverse-$1','reverse-link','queued') returning id
    ), t as (
      insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status)
      select '$ORG',id,'$AGT','reverse-$1','queued' from m returning id,mission_id
    ), i as (
      insert into public.aios_tool_invocations
        (organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key)
      select '$ORG','$AGT',t.id,'support.export_customer_data','support.export_customer_data',
        jsonb_build_object('scope','$1','format','csv'),'low','$REQ',gen_random_uuid(),'reverse-$1-'||gen_random_uuid()
      from t returning id,approval_id
    )
    select (select mission_id from t)||' '||(select id from t)||' '||
           (select id from i)||' '||coalesce((select approval_id::text from i),'x')" | tail -1)
  read -r M T I A <<<"$out"
  need_id "$M"; need_id "$T"; need_id "$I"; need_id "$A"
  q "update public.aios_missions set status='running' where id='$M';
     update public.aios_tasks set status='running' where id='$T';
     update public.aios_tasks set status='blocked_pending_approval' where id='$T';
     update public.aios_missions set status='blocked_pending_approval' where id='$M';
     update public.aios_approvals set invocation_id=NULL, expires_at=now()-interval '5 minutes' where id='$A';" >/dev/null
  [ "$(q "select count(*) from public.aios_tool_invocations where id='$I' and approval_id='$A'")" = 1 ] || { echo "reverse link fixture missing"; exit 2; }
  [ "$(q "select count(*) from public.aios_approvals where id='$A' and invocation_id is null and status='pending'")" = 1 ] || { echo "approval is not reverse-linked/pending"; exit 2; }
  echo "$M $T $I $A"
}
new_stale_sibling() {
  local M="$1" label="$2" T
  T=$(q "insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status)
        values ('$ORG','$M','$AGT','stale-$label','queued') returning id")
  need_id "$T"
  q "begin; set local session_replication_role=replica;
     update public.aios_tasks set status='running',updated_at=now()-interval '1 hour' where id='$T';
     commit;" >/dev/null
  [ "$(q "select count(*) from public.aios_tasks where id='$T' and status='running' and updated_at < now()-interval '10 minutes'")" = 1 ] || { echo "stale task fixture failed"; exit 2; }
  echo "$T"
}

read -r M1 T1 I1 A1 <<<"$(new_chain a)"
read -r M2 T2 I2 A2 <<<"$(new_chain b)"
need_id "$M1"; need_id "$M2"
[ "$M1" != "$M2" ] || { echo "fixture missions must differ"; exit 2; }
S1=$(new_stale_sibling "$M1" a)
S2=$(new_stale_sibling "$M2" b)
need_id "$S1"; need_id "$S2"

# Prove the reverse links resolve to two real missions and produce one ascending mission order.
MAP=$(q "select count(distinct t.mission_id)||'|'||
                string_agg(t.mission_id::text,',' order by t.mission_id,t.id,i.id,ap.id)
         from public.aios_approvals ap
         join public.aios_tool_invocations i on i.approval_id=ap.id
         join public.aios_tasks t on t.id=i.task_id
         where ap.id in ('$A1','$A2') and ap.invocation_id is null")
[ "$MAP" = "2|$(printf '%s\n%s\n' "$M1" "$M2" | sort | paste -sd, -)" ] || { echo "reverse-link mission mapping/order unexpected: $MAP"; exit 2; }

# A blocker holds the first (lowest UUID) mission row. Both real pre-lock helpers must queue
# behind the same first mission, not take different mission locks based on approval UUID order.
FIRST=$(printf '%s\n%s\n' "$M1" "$M2" | sort | head -1)
GATE=942731
( psql "$DB" -X -At -q -v ON_ERROR_STOP=1 <<SQL >"$D/blocker.out" 2>"$D/blocker.err"
begin;
select 'BLOCKER_HAS_MISSION' from public.aios_missions where id='$FIRST' for no key update;
select pg_advisory_lock($GATE);
select pg_advisory_unlock($GATE);
commit;
select 'BLOCKER_DONE';
SQL
echo $? >"$D/blocker.rc" ) &
BLOCK_PID=$!
i=0
until grep -q BLOCKER_HAS_MISSION "$D/blocker.out" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 400 ] && { echo "blocker did not acquire mission"; exit 2; }; sleep 0.05; done

# Deliberately supply approvals in descending mission order. Correct implementation must
# resolve reverse links and re-sort by actual mission/task/invocation/approval tuple.
APP_IDS=$(q "select array_agg(ap.id order by t.mission_id desc,t.id desc,i.id desc,ap.id desc)::text
            from public.aios_approvals ap join public.aios_tool_invocations i on i.approval_id=ap.id
            join public.aios_tasks t on t.id=i.task_id
            where ap.id in ('$A1','$A2') and ap.invocation_id is null")
TASK_IDS="{$S1,$S2}"
( psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -c "select 'APPROVAL_PRELOCK_DONE' from private.aios_prelock_approvals_batch('$APP_IDS'::uuid[])" >"$D/approval.out" 2>"$D/approval.err"; echo $? >"$D/approval.rc" ) &
APP_PID=$!
( psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -c "select 'TASK_PRELOCK_DONE' from private.aios_prelock_tasks_batch('$TASK_IDS'::uuid[])" >"$D/task.out" 2>"$D/task.err"; echo $? >"$D/task.rc" ) &
TASK_PID=$!

i=0
until [ "$(q "select count(*) from pg_stat_activity where wait_event_type='Lock' and query like '%aios_prelock_%' and pid<>pg_backend_pid()")" = 2 ]; do
  i=$((i+1)); [ "$i" -gt 600 ] && { echo "both pre-lock workers did not reach the mission-row barrier"; exit 2; }; sleep 0.05
done
WAITING_AUDIT=$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid=l.pid
                  where l.locktype='advisory' and l.granted
                    and a.query like '%aios_prelock_%' and a.pid<>pg_backend_pid()")
echo "  barrier: both helpers wait on the first mission row; granted advisory locks held by workers=$WAITING_AUDIT"
# Release the blocker. Workers must finish in a common mission-first order without 40P01.
psql "$DB" -X -At -q -c "select pg_advisory_unlock($GATE)" >/dev/null 2>&1 || true
# The blocker owns the advisory lock in its own session, so release it via a second session is
# not possible. Use pg_cancel_backend only after recording the wait barrier; its transaction
# rolls back and releases the mission lock without modifying any fixture.
BLOCK_PID_SQL=$(q "select pid from pg_stat_activity where query like '%pg_advisory_lock($GATE)%' and pid<>pg_backend_pid() order by pid desc limit 1")
[ -n "$BLOCK_PID_SQL" ] && q "select pg_cancel_backend($BLOCK_PID_SQL)" >/dev/null
for f in approval task; do
  i=0; until [ -f "$D/$f.rc" ]; do i=$((i+1)); [ "$i" -gt 600 ] && { echo "$f pre-lock worker timed out"; fail=1; break; }; sleep 0.05; done
done
wait "$APP_PID" || true
wait "$TASK_PID" || true
wait "$BLOCK_PID" || true
[ -f "$D/blocker.rc" ] || echo "1" >"$D/blocker.rc"
DEAD=$(cat "$D"/*.err "$D"/*.out 2>/dev/null | grep -cE '40P01|deadlock detected' || true)
APP_RC=$(cat "$D/approval.rc" 2>/dev/null || echo 99)
TASK_RC=$(cat "$D/task.rc" 2>/dev/null || echo 99)
check "reverse-linked approval helper completed" "$([ "$APP_RC" = 0 ] && echo true || echo false)"
check "stale-task helper completed" "$([ "$TASK_RC" = 0 ] && echo true || echo false)"
check "no deadlock (40P01)" "$([ "$DEAD" = 0 ] && echo true || echo false)"
check "no worker held an advisory audit lock while waiting for mission row" "$([ "$WAITING_AUDIT" = 0 ] && echo true || echo false)"
[ "$APP_RC" = 0 ] || { cat "$D/approval.err"; }
[ "$TASK_RC" = 0 ] || { cat "$D/task.err"; }
echo "== reverse-linked approval / reaper pre-lock regression: $([ "$fail" = 0 ] && echo PASS || echo FAIL)"
exit "$fail"
