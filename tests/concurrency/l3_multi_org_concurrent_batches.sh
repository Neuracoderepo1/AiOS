#!/usr/bin/env bash
# L3 STRESS (not a proof of absence): forced-test requirements 4, 5, 6.
#   4 multiple approvals across different missions   5 multiple organisations   6 repeated concurrent expiry batches
# Each round: ORGS organisations x MPO missions, one lapsed approval per mission; W concurrent expiry workers race
# cancellations of every other mission. Interleaving here is scheduler-dependent by design: the DETERMINISTIC proof is
# l3_audit_lock_forced.sh / l4_reaper_audit_lock_forced.sh; this suite checks convergence + absence of lock-class errors at volume.
# Oracle per round: every worker rc=0; zero 40P01/40001/55P03/57014 anywhere; each lapsed approval ends in exactly one terminal
# state; a final serial pass leaves no lapsed pending approval; no backlog disposition for any fixture approval; cancelled missions
# have no live invocation. A round in which no worker actually processed anything is a FAILED round (no vacuous passes).
# Usage: l3_multi_org_concurrent_batches.sh <conninfo> [rounds=20] [workers=4]   (throwaway DB only)
set -u
DB="$1"; ROUNDS="${2:-20}"; W="${3:-4}"; ORGS=2; MPO=3; fail=0; D=$(mktemp -d); EVID="${L3M_EVIDENCE_DIR:-/tmp/l3-multi-evidence}"; rm -rf "$EVID"; mkdir -p "$EVID"
q() { psql "$DB" -X -At -v ON_ERROR_STOP=1 -c "$1"; }
. "$(dirname "$0")/cron_guard.sh"
cron_pause "$DB" || { echo "cannot guarantee a quiet scheduler"; exit 1; }
trap 'rc=$?; cp -r "$D"/. "$EVID"/ 2>/dev/null; rm -rf "$D"; cron_restore || rc=1; exit $rc' EXIT
REQ=b2b2b2b2-0000-4000-8000-0000000000aa; ADM=b2b2b2b2-0000-4000-8000-0000000000bb
q "insert into auth.users (id,aud,role,email) values ('$REQ','authenticated','authenticated','mo-req@example.test'),('$ADM','authenticated','authenticated','mo-adm@example.test') on conflict do nothing" >/dev/null || exit 2
declare -a ORGID AGT
for o in $(seq 1 $ORGS); do
  ORGID[$o]="b2b2b2b2-0000-4000-8000-00000000010$o"; AGT[$o]="b2b2b2b2-0000-4000-8000-00000000020$o"
  q "insert into public.aios_organizations (id,name) values ('${ORGID[$o]}','mo-org-$o') on conflict do nothing;
     insert into public.aios_organization_members (organization_id,user_id,role) values ('${ORGID[$o]}','$REQ','member'),('${ORGID[$o]}','$ADM','admin') on conflict do nothing;
     insert into public.aios_agents (id,organization_id,agent_key,name,role,status,authority) values ('${AGT[$o]}','${ORGID[$o]}','mo-agent-$o','mo','mo','idle','{\"risk_level\":\"medium\",\"allowed_tools\":[\"support.export_customer_data\"],\"limits\":{}}') on conflict do nothing;
     insert into public.aios_contracts (organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active) values ('${ORGID[$o]}','${AGT[$o]}',1,'medium','[\"support.export_customer_data\"]','{}',true) on conflict (agent_id,version) do update set is_active=true;" >/dev/null || { echo "fixture failed"; exit 2; }
done
new_chain() { # org-index label -> "M T I A"
  local o=$1 l=$2 out M T I A
  out=$(q "with m as (insert into public.aios_missions (organization_id,title,objective,status) values ('${ORGID[$o]}','mo-$l','mo','queued') returning id),
          t as (insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status) select '${ORGID[$o]}',id,'${AGT[$o]}','mo-$l','queued' from m returning id,mission_id),
          i as (insert into public.aios_tool_invocations (organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key)
                select '${ORGID[$o]}','${AGT[$o]}',t.id,'support.export_customer_data','support.export_customer_data',jsonb_build_object('scope','$l','format','csv'),'low','$REQ',gen_random_uuid(),'mo-$l-'||gen_random_uuid() from t returning id,approval_id)
     select (select mission_id from t)||' '||(select id from t)||' '||(select id from i)||' '||coalesce((select approval_id::text from i),'x')" | tail -1)
  read M T I A <<<"$out"
  for x in "$M" "$T" "$I" "$A"; do [[ "$x" =~ ^[0-9a-f-]{36}$ ]] || { echo "FIXTURE FAILED (invalid id)" >&2; exit 2; }; done
  q "update public.aios_missions set status='running' where id='$M'; update public.aios_tasks set status='running' where id='$T'; update public.aios_tasks set status='blocked_pending_approval' where id='$T'; update public.aios_missions set status='blocked_pending_approval' where id='$M';" >/dev/null || exit 2
  echo "$M $T $I $A"
}
TERMINAL="'expired','cancelled','rejected','approved','denied'"
for r in $(seq 1 $ROUNDS); do
  [ "$(q "select count(*) from public.aios_approvals where status='pending' and expires_at <= now()")" = 0 ] || { echo "round $r: dirty candidate set"; exit 2; }
  MS=(); AS=(); IS=(); n=0
  for o in $(seq 1 $ORGS); do for k in $(seq 1 $MPO); do read M T I A <<<"$(new_chain $o r${r}o${o}k$k)"; MS+=("$M"); AS+=("$A"); IS+=("$I"); n=$((n+1)); done; done
  ALL=$(printf "'%s'," "${AS[@]}"); ALL=${ALL%,}
  q "update public.aios_approvals set expires_at = now() - interval '5 minutes' where id in ($ALL)" >/dev/null
  rd="$D/r$r"; mkdir -p "$rd"
  for w in $(seq 1 $W); do ( psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -c "select 'E_RESULT '||private.aios_expire_stale_approvals()::text" >"$rd/e$w.out" 2>"$rd/e$w.err"; echo $? >"$rd/e$w.rc" ) & done
  for idx in $(seq 0 2 $((n-1))); do ( psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -c "update public.aios_missions set status='cancelled' where id='${MS[$idx]}'" >"$rd/c$idx.out" 2>"$rd/c$idx.err"; echo $? >"$rd/c$idx.rc" ) & done
  wait
  # Expiry workers must exit 0. A cancel worker may exit 0 (mission cancelled) or be REFUSED by the state guard (P0001, application-level
  # rejection) when the expiry already failed the mission; any other failure class is a defect. Classified per worker, never ignored.
  rcbad=0; cancel_ok=0; cancel_refused=0
  for f in "$rd"/e*.rc; do [ "$(cat "$f")" = 0 ] || rcbad=$((rcbad+1)); done
  for f in "$rd"/c*.rc; do b=${f%.rc}; if [ "$(cat "$f")" = 0 ]; then cancel_ok=$((cancel_ok+1));
    elif grep -q 'P0001' "$b.err" && grep -q 'invalid mission state transition: failed -> cancelled' "$b.err"; then cancel_refused=$((cancel_refused+1)); else rcbad=$((rcbad+1)); fi; done
  BADTERM=$(q "select count(*) from public.aios_missions where id in ($(printf "'%s'," "${MS[@]}" | sed 's/,$//')) and status not in ('cancelled','failed')")
  LOCKERR=$(cat "$rd"/*.err "$rd"/*.out 2>/dev/null | grep -cE '40P01|40001|55P03|57014|deadlock detected|could not serialize|lock timeout|statement timeout')
  q "select 'E_RESULT '||private.aios_expire_stale_approvals()::text" > "$rd/final-pass.out" 2>"$rd/final-pass.err" || rcbad=$((rcbad+1))
  PEND=$(q "select count(*) from public.aios_approvals where id in ($ALL) and status='pending'")
  NONTERM=$(q "select count(*) from public.aios_approvals where id in ($ALL) and status not in ($TERMINAL)")
  DISP=$(q "select count(*) from public.aios_backlog_dispositions where entity_id in ($ALL)")
  LIVE=$(q "select count(*) from public.aios_tool_invocations i join public.aios_tasks t on t.id=i.task_id join public.aios_missions m on m.id=t.mission_id where m.id in ($(printf "'%s'," "${MS[@]}" | sed 's/,$//')) and m.status='cancelled' and i.status in ('approved','requires_approval')")
  EXPN=$(q "select count(*) from public.aios_approvals where id in ($ALL) and status='expired'")
  ok=true; [ $rcbad = 0 ] && [ "$LOCKERR" = 0 ] && [ "$PEND" = 0 ] && [ "$NONTERM" = 0 ] && [ "$DISP" = 0 ] && [ "$LIVE" = 0 ] && [ "$BADTERM" = 0 ] && [ "$EXPN" -ge 1 ] || ok=false
  echo "round $r: workers=$W cancels_ok=$cancel_ok cancels_refused_by_guard=$cancel_refused rc_bad=$rcbad lock_class_errors=$LOCKERR pending=$PEND nonterminal=$NONTERM dispositions=$DISP live_under_cancelled=$LIVE missions_not_terminal=$BADTERM expired=$EXPN/$n => $($ok && echo PASS || echo FAIL)"
  $ok || fail=1
done
echo; echo "== L3 multi-org concurrent batches ($ROUNDS rounds, $ORGS orgs, $W workers): $([ $fail = 0 ] && echo ALL PASS || echo FAILURES)"; exit $fail
