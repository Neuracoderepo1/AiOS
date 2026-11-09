#!/usr/bin/env bash
# Approval / expiry / reaper lock-order races on REAL PostgreSQL.
# Companion to mission_task_races.sh. Global lock order under test: mission -> task -> invocation -> approval.
# Each scenario releases N pairs of opposing operations simultaneously from an advisory-lock gate (workers are observed parked on the
# gate before it opens; no sleeps are used as proof of ordering) and asserts from COMMITTED state:
#   * no worker aborted with a deadlock (40P01),
#   * mission cancellations all committed (cancel never loses),
#   * no invocation left approved/requires_approval under a cancelled mission.
# Fails closed: a broken fixture exits 2 and reports nothing. Usage: approval_lock_order.sh <DB_URL>  (throwaway CI database only).
set -u
DB="$1"; fail=0; PAIRS=8; D=$(mktemp -d)
q()  { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }
check() { if [ "$2" = "true" ]; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }
. "$(dirname "$0")/cron_guard.sh"
cron_pause "$DB" || { echo "cannot guarantee a quiet scheduler"; exit 1; }
trap 'rc=$?; exec 5>&- 2>/dev/null; kill $(jobs -p) 2>/dev/null; rm -rf "$D"; cron_restore || rc=1; exit $rc' EXIT

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

# gate_run <name> <worker-sql>...: park every worker on an advisory gate (observed), open it, wait, report deadlocks.
GATEN=0
gate_run() {
  local name="$1"; shift; GATEN=$((GATEN+1)); local G=$((941800+GATEN)) w=0 pids=()
  exec 5> >(psql "$DB" -X -At -q > "$D/gate.out" 2>&1); printf 'select pg_advisory_lock(%s);\nselect %s;\n' $G "'GATE_HELD'" >&5
  local i=0; until grep -q GATE_HELD "$D/gate.out" 2>/dev/null; do i=$((i+1)); [ $i -gt 400 ] && { echo "  gate never held"; exit 2; }; sleep 0.05; done
  for sql in "$@"; do w=$((w+1))
    printf "select pg_advisory_lock_shared(%s);\nselect pg_advisory_unlock_shared(%s);\n%s\n" $G $G "$sql" | psql "$DB" -X -At -q > "$D/${name}_$w.out" 2>&1 &
    pids+=($!)
  done
  i=0; until [ "$(q "select count(*) from pg_locks where locktype='advisory' and not granted and objid=$G")" = $# ]; do i=$((i+1)); [ $i -gt 600 ] && { echo "  gate never filled"; fail=1; break; }; sleep 0.05; done
  echo "  barrier: $# workers parked on the gate"
  printf 'select pg_advisory_unlock(%s);\nselect %s;\n' $G "'GATE_OPEN'" >&5; i=0; until grep -q GATE_OPEN "$D/gate.out" 2>/dev/null; do i=$((i+1)); [ $i -gt 400 ] && break; sleep 0.05; done
  wait "${pids[@]}"; exec 5>&-
  DEAD=$(cat "$D"/${name}_*.out | grep -c 'deadlock detected')
}
bad_invocations() { # $1 = space-separated "M T I A" tuples via global array; counts invocations still live under a cancelled mission
  local b=0 c M T I A; for c in "$@"; do read M T I A <<<"$c"; [ "$(q "select count(*) from public.aios_missions m join public.aios_tasks t on t.mission_id=m.id join public.aios_tool_invocations i on i.task_id=t.id where m.id='$M' and m.status='cancelled' and i.status in ('approved','requires_approval')")" = 0 ] || b=$((b+1)); done; echo $b
}
cancelled_count() { local n=0 c M; for c in "$@"; do read M _ <<<"$c"; [ "$(q "select status from public.aios_missions where id='$M'")" = cancelled ] && n=$((n+1)); done; echo $n; }

RESOLVE() { echo "begin; $(as_service) select public.aios_resolve_approval('$2','approved','$ADM','alo'); commit;"; }  # $1 unused
AUTHZ()   { echo "begin; $(as_service) select public.aios_kernel_authorize_invocation('$1'); commit;"; }
CANCEL()  { echo "begin; update public.aios_missions set status='cancelled' where id='$1'; commit; select 'CANCEL_OK';"; }

echo "== L1: approval resolution vs kernel authorizer on the same invocation ($PAIRS pairs)"
ch=(); W=(); for k in $(seq 1 $PAIRS); do c=$(new_chain l1$k); ch+=("$c"); read M T I A <<<"$c"; W+=("$(RESOLVE x $A)" "$(AUTHZ $I)"); done
gate_run l1 "${W[@]}"; echo "  deadlocks=$DEAD"
check "no deadlock between approval resolution and authorizer" "$([ "$DEAD" = 0 ] && echo true || echo false)"

echo "== L2: approval resolution vs mission cancellation ($PAIRS pairs)"
ch=(); W=(); for k in $(seq 1 $PAIRS); do c=$(new_chain l2$k); ch+=("$c"); read M T I A <<<"$c"; W+=("$(RESOLVE x $A)" "$(CANCEL $M)"); done
gate_run l2 "${W[@]}"; cc=$(cancelled_count "${ch[@]}"); bi=$(bad_invocations "${ch[@]}"); echo "  deadlocks=$DEAD cancels_committed=$cc/$PAIRS inconsistent=$bi"
check "no deadlock between approval resolution and mission cancel" "$([ "$DEAD" = 0 ] && echo true || echo false)"
check "every mission cancellation committed" "$([ "$cc" = $PAIRS ] && echo true || echo false)"
check "no live invocation left under a cancelled mission" "$([ "$bi" = 0 ] && echo true || echo false)"

echo "== L3: expiry job vs mission cancellation ($PAIRS pairs, approvals lapsed)"
ch=(); W=(); for k in $(seq 1 $PAIRS); do c=$(new_chain l3$k); ch+=("$c"); read M T I A <<<"$c"; q "update public.aios_approvals set expires_at = now() - interval '5 minutes' where id='$A'" >/dev/null; W+=("select private.aios_expire_stale_approvals();" "$(CANCEL $M)"); done
gate_run l3 "${W[@]}"; cc=$(cancelled_count "${ch[@]}"); bi=$(bad_invocations "${ch[@]}")
errs=$(cat "$D"/l3_*.out | grep -c 'ERROR'); echo "  deadlocks=$DEAD errors=$errs cancels_committed=$cc/$PAIRS inconsistent=$bi"
check "no deadlock between the expiry job and mission cancel" "$([ "$DEAD" = 0 ] && echo true || echo false)"
check "every mission cancellation committed" "$([ "$cc" = $PAIRS ] && echo true || echo false)"
check "no live invocation left under a cancelled mission" "$([ "$bi" = 0 ] && echo true || echo false)"

echo "== L4: stale-task reaper vs mission cancellation ($PAIRS pairs)"
ch=(); W=(); for k in $(seq 1 $PAIRS); do read M T I A <<<"$(new_chain l4$k)"; ch+=("$M $T $I $A")
  q "update public.aios_tasks set status='running' where id='$T'; update public.aios_missions set status='running' where id='$M'" >/dev/null 2>&1 || true
  q "begin; set local session_replication_role = replica; update public.aios_tasks set updated_at = now() - interval '1 hour' where id='$T'; commit;" >/dev/null
  W+=("select private.aios_reap_stale_tasks('10 minutes'::interval);" "$(CANCEL $M)"); done
gate_run l4 "${W[@]}"; cc=$(cancelled_count "${ch[@]}"); echo "  deadlocks=$DEAD cancels_committed=$cc/$PAIRS"
check "no deadlock between the reaper and mission cancel" "$([ "$DEAD" = 0 ] && echo true || echo false)"
check "every mission cancellation committed (or already failed by the reaper)" "$([ "$(for c in "${ch[@]}"; do read M _ <<<"$c"; q "select status from public.aios_missions where id='$M'"; done | grep -cE 'cancelled|failed')" = $PAIRS ] && echo true || echo false)"

echo "== approval lock-order races: $([ $fail = 0 ] && echo ALL PASS || echo FAILURES)"
exit $fail
