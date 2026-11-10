#!/usr/bin/env bash
# Approval / expiry / reaper lock-order races on REAL PostgreSQL.
# Companion to mission_task_races.sh. Global lock order under test: mission -> task -> invocation -> approval.
# Each scenario releases N pairs of opposing operations simultaneously from an advisory-lock gate (workers are observed parked on the
# gate before it opens; no sleeps are used as proof of ordering) and asserts from COMMITTED state:
#   * no worker aborted with a deadlock (40P01),
#   * mission cancellations all committed (cancel never loses),
#   * no invocation left approved/requires_approval under a cancelled mission.
# Evidence (Agent 004): every worker keeps its own stdout, stderr (VERBOSITY=verbose: SQLSTATE/DETAIL/HINT/CONTEXT), SQL and exit code under
# $AOLO_EVIDENCE_DIR (default /tmp/approval-lock-order-evidence); PostgreSQL version + lock settings are recorded up front; the server log
# (deadlock graphs) is collected when docker is available; on any non-zero exit the diagnostics are printed BEFORE the temp dir is removed.
# Fails closed: a broken fixture exits 2 and reports nothing. Usage: approval_lock_order.sh <DB_URL>  (throwaway CI database only).
set -u
DB="$1"; fail=0; PAIRS=8; D=$(mktemp -d); NONZERO=0
EVID="${AOLO_EVIDENCE_DIR:-/tmp/approval-lock-order-evidence}"; rm -rf "$EVID"; mkdir -p "$EVID/workers" || { echo "cannot create evidence dir $EVID"; exit 1; }
RUN_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WOPTS=(-X -At -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -v SHOW_CONTEXT=always)   # per-worker psql options: SQLSTATE + DETAIL/HINT/CONTEXT, exit 3 on error
q()  { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }
check() { if [ "$2" = "true" ]; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }
. "$(dirname "$0")/cron_guard.sh"
cron_pause "$DB" || { echo "cannot guarantee a quiet scheduler"; exit 1; }

record_pg_env() {
  {
    echo "== PostgreSQL version"; psql "$DB" -X -At -c "select version()"
    echo "== lock/timeout settings (pg_settings)"
    psql "$DB" -X -A -c "select name, setting, coalesce(unit,'') as unit, source from pg_settings where name in ('deadlock_timeout','lock_timeout','statement_timeout','idle_in_transaction_session_timeout','max_locks_per_transaction','max_pred_locks_per_transaction','max_connections','log_lock_waits','log_min_error_statement','log_min_messages','default_transaction_isolation','synchronous_commit') order by name"
  } > "$EVID/pg_env.txt" 2>&1
  cat "$EVID/pg_env.txt"
}
collect_server_diag() {
  { echo "== pg_stat_activity at exit"; psql "$DB" -X -A -c "select pid,state,wait_event_type,wait_event,left(query,160) as query from pg_stat_activity where datname=current_database() and pid<>pg_backend_pid() order by pid"
    echo "== ungranted locks at exit"; psql "$DB" -X -A -c "select locktype,mode,pid,relation::regclass,objid from pg_locks where not granted"
  } > "$EVID/server_state_at_exit.txt" 2>&1
  cp "$D/gate.out" "$EVID/gate.out" 2>/dev/null
  local c=""; command -v docker >/dev/null 2>&1 && c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^supabase_db_' | head -1)
  if [ -n "$c" ]; then docker logs --since "$RUN_START" "$c" > "$EVID/postgres_server.log" 2>&1
  else echo "PostgreSQL server log unavailable: no docker / supabase_db container reachable from this shell" > "$EVID/postgres_server.log"; fi
}
print_failure_diag() { # stdout, before $D is removed. Only workers with non-zero exit or any stderr are printed in full; all exit codes are listed.
  echo "================ FAILURE DIAGNOSTICS (printed before cleanup) ================"
  echo "evidence dir: $EVID  run_start: $RUN_START  nonzero_workers_seen: $NONZERO"
  [ -f "$EVID/pg_env.txt" ] && cat "$EVID/pg_env.txt"
  local f b r
  echo "--- all worker exit codes"; for f in "$EVID"/workers/*.rc; do [ -e "$f" ] && printf '%s=%s ' "$(basename "$f" .rc)" "$(cat "$f")"; done; echo
  for f in "$EVID"/workers/*.rc; do [ -e "$f" ] || continue; b=${f%.rc}; r=$(cat "$f")
    if [ "$r" != 0 ] || [ -s "$b.err" ]; then
      echo "--- worker $(basename "$b") rc=$r"; echo "  sql: $(head -c 400 "$b.sql" 2>/dev/null | tr '\n' ' ')"
      echo "  stdout:"; sed 's/^/    /' "$b.out" | head -30; echo "  stderr (SQLSTATE/DETAIL/HINT/CONTEXT):"; sed 's/^/    /' "$b.err" | head -50
    fi
  done
  echo "--- gate session output"; head -20 "$D/gate.out" 2>/dev/null
  echo "--- server state at exit"; cat "$EVID/server_state_at_exit.txt" 2>/dev/null | head -40
  echo "--- postgres server log: deadlock graphs / errors"; grep -nE -B1 -A14 'deadlock detected|ERROR:' "$EVID/postgres_server.log" 2>/dev/null | head -150
  echo "================ END FAILURE DIAGNOSTICS ================"
}
# NOTE: the previous trap ran `exec 5>&- 2>/dev/null`, which silenced this shell's own stderr for the rest of cleanup. fd 5 is now closed on its own.
trap 'rc=$?; exec 5>&-; kill $(jobs -p) 2>/dev/null; collect_server_diag; [ $rc -ne 0 ] && print_failure_diag; rm -rf "$D"; cron_restore || rc=1; exit $rc' EXIT
record_pg_env

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
    local wf="$EVID/workers/${name}_$w"; printf '%s\n' "$sql" > "$wf.sql"
    ( printf "select pg_advisory_lock_shared(%s);\nselect pg_advisory_unlock_shared(%s);\n%s\n" $G $G "$sql" | psql "$DB" "${WOPTS[@]}" > "$wf.out" 2> "$wf.err"; echo $? > "$wf.rc" ) &
    pids+=($!)
  done
  i=0; until [ "$(q "select count(*) from pg_locks where locktype='advisory' and not granted and objid=$G")" = $# ]; do i=$((i+1)); [ $i -gt 600 ] && { echo "  gate never filled"; fail=1; break; }; sleep 0.05; done
  echo "  barrier: $# workers parked on the gate"
  printf 'select pg_advisory_unlock(%s);\nselect %s;\n' $G "'GATE_OPEN'" >&5; i=0; until grep -q GATE_OPEN "$D/gate.out" 2>/dev/null; do i=$((i+1)); [ $i -gt 400 ] && break; sleep 0.05; done
  wait "${pids[@]}"; exec 5>&-
  DEAD=$(cat "$EVID"/workers/${name}_*.err "$EVID"/workers/${name}_*.out | grep -cE '40P01|deadlock detected')
  local f b r rcs=""; for f in "$EVID"/workers/${name}_*.rc; do b=$(basename "$f" .rc); r=$(cat "$f"); rcs="$rcs $b=$r"
    if [ "$r" != 0 ]; then NONZERO=$((NONZERO+1)); printf '%s\trc=%s\tsqlstate=%s\n' "$b" "$r" "$(grep -ohE '(ERROR|FATAL):  [0-9A-Z]{5}' "$EVID/workers/$b.err" | head -1 | awk '{print $2}')" >> "$EVID/nonzero_workers.tsv"; fi; done
  echo "  worker exit codes:$rcs"
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
errs=$(cat "$EVID"/workers/l3_*.err "$EVID"/workers/l3_*.out | grep -c 'ERROR'); echo "  deadlocks=$DEAD errors=$errs cancels_committed=$cc/$PAIRS inconsistent=$bi"
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
