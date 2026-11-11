#!/usr/bin/env bash
# L3 forced interleaving (DETERMINISTIC): the exact cycle from the PostgreSQL deadlock graph, no timing luck.
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
trap 'rc=$?; psql "$DB" -X -q -c "drop trigger if exists l3_defer_test_trg on public.aios_approvals; drop function if exists public.l3_defer_test_fn()" >/dev/null 2>&1; exec 5>&- 2>/dev/null; kill $(jobs -p) 2>/dev/null; cp -r "$D"/. "$EVID"/ 2>/dev/null; rm -rf "$D"; cron_restore || rc=1; exit $rc' EXIT
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


echo "== fixtures: two lapsed approvals; a test-only trigger forces a failure INSIDE the per-record handler (no timing involved)"
read M1 T1 I1 A1 <<<"$(new_chain d1)"; read M2 T2 I2 A2 <<<"$(new_chain d2)"; need_ids "$M1" "$T1" "$I1" "$A1" "$M2" "$T2" "$I2" "$A2"
q "update public.aios_approvals set expires_at = now() - interval '5 minutes' where id in ('$A1','$A2')" >/dev/null
[ "$(q "select count(*) from public.aios_approvals where status='pending' and expires_at <= now()")" = 2 ] || { echo "FIXTURE: other lapsed approvals exist; run on a clean database"; exit 2; }
q "create or replace function public.l3_defer_test_fn() returns trigger language plpgsql as \$t\$ begin
     if new.status = 'expired' and new.id = '$A1' then raise exception 'forced lock conflict' using errcode = '40P01'; end if;
     if new.status = 'expired' and new.id = '$A2' then raise exception 'forced data error' using errcode = 'XX001'; end if;
     return new; end \$t\$;
   create trigger l3_defer_test_trg before update on public.aios_approvals for each row execute function public.l3_defer_test_fn();" >/dev/null
echo "== run 1: A1 fails with 40P01 (deadlock victim), A2 fails with a non-lock error"
R=$(q "select private.aios_expire_stale_approvals()::text") || { echo "  job raised"; exit 1; }
j() { q "select ('$R'::jsonb ->> '$1')"; }
check "lock conflict was deferred and counted (lock_conflicts_deferred=1)" "$([ "$(j lock_conflicts_deferred)" = 1 ] && echo true || echo false)"
check "non-lock error still counted as transition error (transition_errors_skipped=1)" "$([ "$(j transition_errors_skipped)" = 1 ] && echo true || echo false)"
check "A1 (deadlock victim) is still pending and its invocation untouched" "$([ "$(q "select status from public.aios_approvals where id='$A1'")" = pending ] && [ "$(q "select status from public.aios_tool_invocations where id='$I1'")" = requires_approval ] && echo true || echo false)"
check "A1 got NO permanent manual_review disposition" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$A1'")" = 0 ] && echo true || echo false)"
check "A2 (non-lock error) keeps the existing behaviour: manual_review disposition written" "$([ "$(q "select count(*) from public.aios_backlog_dispositions where entity_id='$A2' and disposition='manual_review'")" = 1 ] && echo true || echo false)"
echo "== run 2: conflict gone; the deferred record must converge on the next run"
q "drop trigger l3_defer_test_trg on public.aios_approvals" >/dev/null
R=$(q "select private.aios_expire_stale_approvals()::text") || { echo "  job raised"; exit 1; }
check "A1 expired on the next run" "$([ "$(q "select status from public.aios_approvals where id='$A1'")" = expired ] && echo true || echo false)"
echo; echo "== L3 lock-conflict deferral: $([ $fail = 0 ] && echo ALL PASS || echo FAILURES)"; exit $fail
