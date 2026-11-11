#!/usr/bin/env bash
# L3 subtree-level forced interleaving (DETERMINISTIC). Companion to l3_audit_lock_forced.sh.
#
# WHY THIS EXISTS: l3_audit_lock_forced.sh makes the contender hold the MISSION row, so it can only ever notice a missing mission-level pre-lock.
# Removing the task-, invocation- or approval-level lock from private.aios_lock_mission_subtree() survived every other test (mutation probe, PR28 review).
# The invariant the pre-lock exists to protect is: "the expiry job never WAITS for a row lock while holding the org audit advisory lock".
# A contender that holds a lower-level row WITHOUT the mission row (e.g. a heartbeat-style non-status UPDATE, or any lock holder that is not mission-first)
# is the only way to observe the lower levels. This script does exactly that, once per level, and asserts the invariant directly.
#
#   LEVEL task        : contender holds T2 (FOR NO KEY UPDATE)
#   LEVEL invocation  : contender holds I2 (FOR UPDATE)
#   LEVEL approval    : contender holds A2 (FOR UPDATE)
# The contender never needs the audit lock, so the correct code must finish WITHOUT any deadlock; what distinguishes correct from mutated code is whether the
# expiry job, while blocked behind the contender, holds the audit advisory lock (A1 was already processed => its audit write took that lock in the mutant).
# Barriers are event based (pg_stat_activity / pg_locks), never sleeps. Usage: l3_audit_lock_subtree_levels.sh <conninfo>   (throwaway DB only)
set -u
DB="$1"; fail=0; D=$(mktemp -d); EVID="${L3S_EVIDENCE_DIR:-/tmp/l3-subtree-levels-evidence}"; rm -rf "$EVID"; mkdir -p "$EVID"
q()  { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }
check() { if [ "$2" = "true" ]; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }
. "$(dirname "$0")/cron_guard.sh"
cron_pause "$DB" || { echo "cannot guarantee a quiet scheduler"; exit 1; }
trap 'rc=$?; exec 5>&- 2>/dev/null; kill $(jobs -p) 2>/dev/null; cp -r "$D"/. "$EVID"/ 2>/dev/null; rm -rf "$D"; cron_restore || rc=1; exit $rc' EXIT
ORG=a2a2a2a2-0000-4000-8000-000000000001; AGT=a2a2a2a2-0000-4000-8000-000000000002
REQ=a2a2a2a2-0000-4000-8000-000000000003; ADM=a2a2a2a2-0000-4000-8000-000000000004
q "insert into auth.users (id,aud,role,email) values ('$REQ','authenticated','authenticated','als-req@example.test'),('$ADM','authenticated','authenticated','als-adm@example.test') on conflict do nothing;
   insert into public.aios_organizations (id,name) values ('$ORG','als-org') on conflict do nothing;
   insert into public.aios_organization_members (organization_id,user_id,role) values ('$ORG','$REQ','member'),('$ORG','$ADM','admin') on conflict do nothing;
   insert into public.aios_agents (id,organization_id,agent_key,name,role,status,authority) values ('$AGT','$ORG','als-agent','als','als','idle','{\"risk_level\":\"medium\",\"allowed_tools\":[\"support.export_customer_data\"],\"limits\":{}}') on conflict do nothing;
   insert into public.aios_contracts (organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active) values ('$ORG','$AGT',1,'medium','[\"support.export_customer_data\"]','{}',true) on conflict (agent_id,version) do update set is_active=true;" >/dev/null || { echo "fixture failed"; exit 2; }

need_ids() { for x in "$@"; do [[ "$x" =~ ^[0-9a-f-]{36}$ ]] || { echo "  FIXTURE FAILED (empty/invalid id): refusing to report any result"; exit 2; }; done; }

# new_chain <label>: mission+task blocked_pending_approval, invocation requires_approval with a pending approval. Echoes "M T I A".
new_chain() {
  local out; out=$(q "with m as (insert into public.aios_missions (organization_id,title,objective,status) values ('$ORG','als-$1','als','queued') returning id),
          t as (insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status) select '$ORG',id,'$AGT','als-$1','queued' from m returning id,mission_id),
          i as (insert into public.aios_tool_invocations (organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key)
                select '$ORG','$AGT',t.id,'support.export_customer_data','support.export_customer_data',jsonb_build_object('scope','$1','format','csv'),'low','$REQ',gen_random_uuid(),'als-$1-'||gen_random_uuid() from t returning id,approval_id)
     select (select mission_id from t)||' '||(select id from t)||' '||(select id from i)||' '||coalesce((select approval_id::text from i),'x')" | tail -1)
  read M T I A <<<"$out"; need_ids "$M" "$T" "$I" "$A"
  q "update public.aios_missions set status='running' where id='$M'; update public.aios_tasks set status='running' where id='$T'; update public.aios_tasks set status='blocked_pending_approval' where id='$T'; update public.aios_missions set status='blocked_pending_approval' where id='$M';" >/dev/null || { echo "  chain transition failed"; exit 2; }
  [ "$(q "select status from public.aios_tool_invocations where id='$I'")" = requires_approval ] || { echo "  FIXTURE: invocation is not requires_approval"; exit 2; }
  echo "$M $T $I $A"
}

run_level() { # <level> <gate-key>
  local LEVEL="$1" G="$2" TBL ID CLAUSE
  echo "== LEVEL $LEVEL: two lapsed approvals (A1 older than A2), each on its own mission"
  local M1 T1 I1 A1 M2 T2 I2 A2
  read M1 T1 I1 A1 <<<"$(new_chain ${LEVEL}1)"; read M2 T2 I2 A2 <<<"$(new_chain ${LEVEL}2)"; need_ids "$M1" "$T1" "$I1" "$A1" "$M2" "$T2" "$I2" "$A2"
  q "update public.aios_approvals set expires_at = now() - interval '5 minutes' where id in ('$A1','$A2')" >/dev/null
  [ "$(q "select count(*) from public.aios_approvals where id in ('$A1','$A2') and status='pending'")" = 2 ] || { echo "FIXTURE: approvals not pending"; exit 2; }
  [ "$(q "select (select created_at from public.aios_approvals where id='$A1') < (select created_at from public.aios_approvals where id='$A2')")" = t ] || { echo "FIXTURE: A1 must be older"; exit 2; }
  [ "$(q "select count(*) from public.aios_approvals where status='pending' and expires_at <= now()")" = 2 ] || { echo "FIXTURE: other lapsed approvals exist; run on a clean database"; exit 2; }
  case "$LEVEL" in
    task)       TBL=public.aios_tasks;            ID=$T2; CLAUSE="for no key update";;
    invocation) TBL=public.aios_tool_invocations; ID=$I2; CLAUSE="for update";;
    approval)   TBL=public.aios_approvals;        ID=$A2; CLAUSE="for update";;
    *) echo "bad level"; exit 2;;
  esac
  local W="$D/$LEVEL"; mkdir -p "$W"
  exec 5> >(psql "$DB" -X -At -q > "$W/gate.out" 2>&1); printf 'select pg_advisory_lock(%s);\nselect %s;\n' $G "'GATE_HELD'" >&5
  local i=0; until grep -q GATE_HELD "$W/gate.out" 2>/dev/null; do i=$((i+1)); [ $i -gt 400 ] && { echo "gate never held"; exit 2; }; sleep 0.05; done
  echo "== C: contender takes the $LEVEL row lock of chain 2 (NOT the mission row), then parks on the gate"
  ( printf "begin;\nselect 'C_HAS_ROW' from $TBL where id='$ID' $CLAUSE;\nselect pg_advisory_lock_shared($G);\nselect pg_advisory_unlock_shared($G);\ncommit;\nselect 'C_DONE';\n" \
    | psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose > "$W/c.out" 2> "$W/c.err"; echo $? > "$W/c.rc" ) &
  i=0; until grep -q C_HAS_ROW "$W/c.out" 2>/dev/null; do i=$((i+1)); [ $i -gt 400 ] && { echo "C never obtained the row lock"; exit 2; }; sleep 0.05; done
  i=0; until [ "$(q "select count(*) from pg_locks where locktype='advisory' and not granted and objid=$G")" = 1 ]; do i=$((i+1)); [ $i -gt 400 ] && { echo "C never parked"; exit 2; }; sleep 0.05; done
  echo "  barrier: C holds the $LEVEL row and is parked on the gate"
  echo "== E: expiry job starts and must end up WAITING behind C"
  ( psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -c "select 'E_RESULT ' || private.aios_expire_stale_approvals()::text" > "$W/e.out" 2> "$W/e.err"; echo $? > "$W/e.rc" ) &
  i=0; until [ "$(q "select count(*) from pg_stat_activity where wait_event_type='Lock' and wait_event='transactionid' and query like '%aios_expire_stale_approvals%' and pid<>pg_backend_pid()")" = 1 ]; do i=$((i+1)); [ $i -gt 600 ] && { echo "E never blocked on the row lock"; exit 2; }; sleep 0.05; done
  local HELD; HELD=$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid=l.pid where l.locktype='advisory' and l.granted and a.query like '%aios_expire_stale_approvals%'")
  echo "  barrier: E is blocked on a row lock held by C; E holds the org AUDIT advisory lock: $([ "$HELD" -ge 1 ] && echo YES || echo NO)"
  echo "$HELD" > "$W/e_holds_audit_lock_while_waiting"
  echo "== release C"
  printf 'select pg_advisory_unlock(%s);\n' $G >&5
  i=0; until [ -f "$W/c.rc" ] && [ -f "$W/e.rc" ]; do i=$((i+1)); [ $i -gt 700 ] && { echo "  workers did not finish (hang)"; fail=1; break; }; sleep 0.05; done
  exec 5>&-; wait 2>/dev/null
  local DEAD; DEAD=$(cat "$W"/c.err "$W"/c.out "$W"/e.err "$W"/e.out 2>/dev/null | grep -cE '40P01|deadlock detected')
  echo "  C rc=$(cat "$W/c.rc" 2>/dev/null) E rc=$(cat "$W/e.rc" 2>/dev/null) deadlocks=$DEAD E_holds_audit_lock_while_waiting=$HELD"
  check "[$LEVEL] E did not hold the org audit advisory lock while waiting for the $LEVEL row" "$([ "$HELD" = 0 ] && echo true || echo false)"
  check "[$LEVEL] no deadlock (40P01)" "$([ "$DEAD" = 0 ] && echo true || echo false)"
  check "[$LEVEL] contender released and exited 0" "$([ "$(cat "$W/c.rc" 2>/dev/null)" = 0 ] && grep -q C_DONE "$W/c.out" && echo true || echo false)"
  check "[$LEVEL] expiry job finished successfully" "$([ "$(cat "$W/e.rc" 2>/dev/null)" = 0 ] && grep -q E_RESULT "$W/e.out" && echo true || echo false)"
  check "[$LEVEL] both approvals expired, none pending, no lock conflict recorded as a disposition" "$([ "$(q "select count(*) from public.aios_approvals where id in ('$A1','$A2') and status='expired'")" = 2 ] && [ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id in ('$A1','$A2')")" = 0 ] && echo true || echo false)"
}

run_level task 942001
run_level invocation 942002
run_level approval 942003
echo; echo "== L3 subtree-level forced interleaving: $([ $fail = 0 ] && echo ALL PASS || echo FAILURES)"; exit $fail
