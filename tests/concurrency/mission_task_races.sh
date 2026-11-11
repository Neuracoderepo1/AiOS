#!/usr/bin/env bash
# Mission/task authority races on REAL PostgreSQL (Priority Two).
#
# Two real psql sessions (A, B) are driven step by step. Ordering is forced by EVENT barriers, never by sleeps:
#   * "B is blocked" is observed from pg_locks / pg_stat_activity (wait_event_type = 'Lock') for B's backend pid.
#   * "step finished" is observed from a sentinel row echoed back by the session.
# The polling loops below only bound how long we wait for an event; they are not used as proof of ordering.
#
# Every scenario asserts the DESIRED invariant from committed state. A scenario that fails documents a real defect.
# Usage: mission_task_races.sh <DB_URL>   (throwaway CI database only: commits fixtures)
set -u
DB="$1"; fail=0; D=$(mktemp -d); trap 'exec 3>&- 4>&- 2>/dev/null; kill $(jobs -p) 2>/dev/null; rm -rf "$D"' EXIT
q()  { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }
check() { if [ "$2" = "true" ]; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }

# ---- session driver -------------------------------------------------------------------------------------------------
# open_sess <name> <fd>: starts a long-lived psql reading commands from a FIFO; output goes to $D/<name>.out
open_sess() {
  mkfifo "$D/$1.in"
  psql "$DB" -X -At -q < "$D/$1.in" > "$D/$1.out" 2>&1 &
  eval "exec $2>\"$D/$1.in\""
}
# send <fd> <sql>: write a command; then wait for its sentinel so the step is known to have completed (or errored)
n=0
step() { # step <name> <fd> <sql>
  n=$((n+1)); local tag="STEP_$n"
  printf '%s\nselect %s;\n' "$3" "'$tag'" >&"$2"
  wait_out "$1" "$tag" 600
}
fire() { # fire <fd> <sql>: send WITHOUT waiting (used for a statement that is expected to block)
  printf '%s\n' "$2" >&"$1"
}
wait_out() { local i=0; until grep -q "$2" "$D/$1.out" 2>/dev/null; do i=$((i+1)); [ $i -gt $3 ] && { echo "  TIMEOUT waiting for $2 in $1"; return 1; }; sleep 0.05; done; }
pid_of() { step "$1" "$2" "select 'PID='||pg_backend_pid();" >/dev/null; grep -o 'PID=[0-9]*' "$D/$1.out" | tail -1 | cut -d= -f2; }
blocked() { # blocked <pid>: true once that backend is waiting on a heavyweight lock
  local i=0; until [ "$(q "select count(*) from pg_stat_activity where pid=$1 and wait_event_type='Lock'")" = 1 ]; do i=$((i+1)); [ $i -gt 400 ] && return 1; sleep 0.05; done; return 0; }

# ---- fixture ----------------------------------------------------------------------------------------------------------
ORG=c5c5c5c5-0000-4000-8000-000000000001; AGT=c5c5c5c5-0000-4000-8000-000000000002; USR=c5c5c5c5-0000-4000-8000-000000000003
q "insert into auth.users (id, aud, role, email) values ('$USR','authenticated','authenticated','mtr@example.test') on conflict do nothing;
   insert into public.aios_organizations (id,name) values ('$ORG','mtr-org') on conflict do nothing;
   insert into public.aios_organization_members (organization_id,user_id,role) values ('$ORG','$USR','member') on conflict do nothing;
   insert into public.aios_agents (id,organization_id,agent_key,name,role,status,authority) values ('$AGT','$ORG','mtr-agent','mtr','mtr','idle','{\"risk_level\":\"medium\",\"allowed_tools\":[\"support.search_tickets\"],\"limits\":{}}') on conflict do nothing;
   insert into public.aios_contracts (organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active) values ('$ORG','$AGT',1,'medium','[\"support.search_tickets\"]','{}',true) on conflict (agent_id,version) do update set is_active=true;" >/dev/null || { echo "fixture failed"; exit 1; }

# new_chain <label>: a RUNNING mission, a RUNNING task under it, and an auto-approved invocation for that task. Echoes "mission task invocation".
new_chain() {
  q "with m as (insert into public.aios_missions (organization_id,title,objective,status) values ('$ORG','mtr-$1','mtr','queued') returning id),
          t as (insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status) select '$ORG',id,'$AGT','mtr-$1','queued' from m returning id,mission_id),
          i as (insert into public.aios_tool_invocations (organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key)
                select '$ORG','$AGT',t.id,'support.search_tickets','support.search_tickets',jsonb_build_object('limit',2),'low','$USR',gen_random_uuid(),'mtr-$1-'||gen_random_uuid() from t returning id)
     select (select mission_id from t)||' '||(select id from t)||' '||(select id from i)" | tail -1
}
need_ids() { for x in "$@"; do [[ "$x" =~ ^[0-9a-f-]{36}$ ]] || { echo "  FIXTURE FAILED (empty/invalid id): refusing to report any result"; exit 2; }; done; }
as_service() { echo "set local role service_role; select set_config('request.jwt.claims','{\"role\":\"service_role\"}',true);"; }
state() { q "select (select status from public.aios_missions where id='$1')||'/'||(select status from public.aios_tasks where id='$2')||'/'||(select status from public.aios_tool_invocations where id='$3')"; }

if [ "${PREFIX_CHARACTERIZATION:-0}" = 1 ]; then
echo "== R1 (pre-fix characterization): authorizer holds the invocation lock first, as the PRE-FIX function did"
read M T I <<<"$(new_chain r1)"; need_ids "$M" "$T" "$I"
q "update public.aios_missions set status='running' where id='$M'; update public.aios_tasks set status='running' where id='$T'" >/dev/null
echo "  precondition: mission/task/invocation = $(state $M $T $I)"
open_sess A 3; open_sess B 4; PA=$(pid_of A 3); PB=$(pid_of B 4)
# A takes the invocation row lock FIRST, exactly as the kernel authorizer does as its first act (select ... for update)
step A 3 "begin; select 'held' from public.aios_tool_invocations where id='$I' for update;" >/dev/null
# B cancels the parent mission: its cascade must reach the invocation, which A holds, so B blocks
step B 4 "begin;" >/dev/null
fire 4 "update public.aios_missions set status='cancelled' where id='$M';"
blocked "$PB" && echo "  barrier: B is blocked behind A (event observed in pg_stat_activity)" || { echo "  barrier never reached"; fail=1; }
# A now runs the real kernel authorizer (re-entrant on its own invocation lock); it needs the mission lock B already holds
fire 3 "$(as_service) select 'AUTH_RESULT='||(public.aios_kernel_authorize_invocation('$I')).status;"
wait_out A "AUTH_RESULT\|ERROR" 400; wait_out B "ERROR\|UPDATE" 400
fire 3 "commit;"; fire 4 "commit;"; step A 3 "select 1;" >/dev/null; step B 4 "select 1;" >/dev/null
echo "  A: $(grep -E 'AUTH_RESULT|ERROR' "$D/A.out" | head -2 | tr '\n' ' ')"; echo "  B: $(grep -E 'ERROR' "$D/B.out" | head -2 | tr '\n' ' ')"
check "no deadlock: neither session aborted with 40P01 (lock order must be consistent)" "$([ "$(cat "$D"/A.out "$D"/B.out | grep -c 'deadlock detected')" = 0 ] && echo true || echo false)"
check "mission cancellation committed (cancel must never lose to an executor)" "$([ "$(q "select status from public.aios_missions where id='$M'")" = cancelled ] && echo true || echo false)"
check "no invocation left executing under a cancelled mission" "$([ "$(q "select count(*) from public.aios_tool_invocations where id='$I' and status='executing'")" = 0 ] && echo true || echo false)"
echo "  final mission/task/invocation = $(state $M $T $I)"
exec 3>&- 4>&-; kill $(jobs -p) 2>/dev/null; n=0

fi

echo "== R1b: 8 authorizer/cancel pairs released simultaneously from an advisory-lock gate (regression for lock order)"
GATE=941700; PAIRS=8; rm -f "$D"/g_*.out; chains=(); WK=()
for k in $(seq 1 $PAIRS); do read M T I <<<"$(new_chain r1b$k)"; need_ids "$M" "$T" "$I"
  q "update public.aios_missions set status='running' where id='$M'; update public.aios_tasks set status='running' where id='$T'" >/dev/null; chains+=("$M $T $I"); done
# the gate: this session holds an exclusive advisory lock; every worker blocks on a shared request until it is released together
exec 5> >(psql "$DB" -X -At -q > "$D/gate.out" 2>&1); printf 'select pg_advisory_lock(%s);\nselect %s;\n' $GATE "'GATE_HELD'" >&5; wait_out gate GATE_HELD 400
GP=$(q "select pid from pg_locks where locktype='advisory' and granted and objid=$GATE limit 1")
k=0; for c in "${chains[@]}"; do k=$((k+1)); read M T I <<<"$c"
  printf "select pg_advisory_lock_shared(%s);\nselect pg_advisory_unlock_shared(%s);\nbegin;\nupdate public.aios_missions set status='cancelled' where id='%s';\ncommit;\nselect 'CANCEL_OK';\n" $GATE $GATE $M | psql "$DB" -X -At -q > "$D/g_c$k.out" 2>&1 &
  WK+=($!)
  printf "select pg_advisory_lock_shared(%s);\nselect pg_advisory_unlock_shared(%s);\nbegin;\n%s\nselect 'AUTH='||(public.aios_kernel_authorize_invocation('%s')).status;\ncommit;\n" $GATE $GATE "$(as_service)" $I | psql "$DB" -X -At -q > "$D/g_a$k.out" 2>&1 &
  WK+=($!)
done
# barrier: all 2*PAIRS workers are parked on the gate (observed, not slept)
i=0; until [ "$(q "select count(*) from pg_locks where locktype='advisory' and not granted and objid=$GATE")" = $((PAIRS*2)) ]; do i=$((i+1)); [ $i -gt 600 ] && { echo "  gate never filled"; fail=1; break; }; sleep 0.05; done
echo "  barrier: $((PAIRS*2)) workers parked on the gate"
printf 'select pg_advisory_unlock(%s);\nselect %s;\n' $GATE "'GATE_OPEN'" >&5; wait_out gate GATE_OPEN 400; wait "${WK[@]}"
dead=$(cat "$D"/g_*.out | grep -c 'deadlock detected'); canc=0; for c in "${chains[@]}"; do read M T I <<<"$c"; [ "$(q "select status from public.aios_missions where id='$M'")" = cancelled ] && canc=$((canc+1)); done  # committed state, not worker output
refused=$(cat "$D"/g_a*.out | grep -c 'ERROR'); won=$(cat "$D"/g_a*.out | grep -c 'AUTH=executing')
echo "  deadlocks=$dead cancels_committed=$canc/$PAIRS authorizer: executing=$won refused=$refused"
check "no deadlock under simultaneous authorize/cancel (lock order consistent)" "$([ "$dead" = 0 ] && echo true || echo false)"
check "every mission cancellation committed (cancel never loses to an executor)" "$([ "$canc" = $PAIRS ] && echo true || echo false)"
bad=0; for c in "${chains[@]}"; do read M T I <<<"$c"; ms=$(q "select status from public.aios_missions where id='$M'"); is=$(q "select status from public.aios_tool_invocations where id='$I'"); { [ "$ms" = cancelled ] && [ "$is" != approved ]; } || bad=$((bad+1)); done
check "every chain converged: mission cancelled and no invocation left 'approved' ($bad inconsistent)" "$([ "$bad" = 0 ] && echo true || echo false)"
exec 5>&-

echo "== R2: task cancelled directly (not via mission) with an approved invocation"
read M T I <<<"$(new_chain r2)"; need_ids "$M" "$T" "$I"
q "update public.aios_missions set status='running' where id='$M'; update public.aios_tasks set status='running' where id='$T'; update public.aios_tasks set status='cancelled' where id='$T'" >/dev/null
echo "  after task cancel: mission/task/invocation = $(state $M $T $I)"
check "no orphaned 'approved' invocation remains once its task is cancelled" "$([ "$(q "select status from public.aios_tool_invocations where id='$I'")" != approved ] && echo true || echo false)"
res=$(q "begin; $(as_service) select 'OK' from (select public.aios_kernel_authorize_invocation('$I')) x; commit;" 2>&1 | tail -1)
check "kernel refuses to execute for a cancelled task (got: $(echo "$res" | cut -c1-70))" "$(echo "$res" | grep -qi 'not executable\|invocation' && echo true || echo false)"

echo "== mission/task races: $([ $fail = 0 ] && echo ALL PASS || echo FAILURES)"
exit $fail
