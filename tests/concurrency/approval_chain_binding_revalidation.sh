#!/usr/bin/env bash
# Forced PostgreSQL interleaving: mutate the invocation->task binding while the
# chain-lock worker is blocked on the original mission row. The worker must either
# reject the changed post-lock snapshot with 40001, or the database must prove the
# binding column is immutable to the migration runner. Disposable CI stack only.
set -euo pipefail
DB="$1"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT

ORG=ab030101-0000-4000-8000-000000000001
AGT=ab030101-0000-4000-8000-000000000002
REQ=ab030101-0000-4000-8000-000000000003
ADM=ab030101-0000-4000-8000-000000000004
M1=ab030101-0000-4000-8000-000000000005
T1=ab030101-0000-4000-8000-000000000006
M2=ab030101-0000-4000-8000-000000000007
T2=ab030101-0000-4000-8000-000000000008
INV=ab030101-0000-4000-8000-000000000009
q() { psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -c "$1"; }

echo "== approval-chain post-lock binding revalidation"
psql "$DB" -X -q -v ON_ERROR_STOP=1 <<SQL
insert into auth.users(id,aud,role,email) values
 ('$REQ','authenticated','authenticated','bind-req@example.test'),
 ('$ADM','authenticated','authenticated','bind-adm@example.test')
on conflict (id) do nothing;
insert into public.aios_organizations(id,name) values ('$ORG','binding-race-fixture') on conflict (id) do nothing;
insert into public.aios_organization_members(organization_id,user_id,role) values
 ('$ORG','$REQ','member'),('$ORG','$ADM','admin') on conflict do nothing;
insert into public.aios_agents(id,organization_id,agent_key,name,role,status,authority)
values ('$AGT','$ORG','binding-race-agent','binding-race','binding-race','idle',
 jsonb_build_object('risk_level','medium','allowed_tools',jsonb_build_array('support.export_customer_data'),'limits','{}'::jsonb))
on conflict (id) do nothing;
insert into public.aios_contracts(organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active)
values ('$ORG','$AGT',1,'medium',jsonb_build_array('support.export_customer_data'),'{}'::jsonb,true)
on conflict (agent_id,version) do update set is_active=true;
insert into public.aios_missions(id,organization_id,title,objective,status)
values ('$M1','$ORG','binding-race-one','binding-race','queued'),
       ('$M2','$ORG','binding-race-two','binding-race','queued');
insert into public.aios_tasks(id,organization_id,mission_id,assigned_agent_id,title,status)
values ('$T1','$ORG','$M1','$AGT','binding-race-one','queued'),
       ('$T2','$ORG','$M2','$AGT','binding-race-two','queued');
insert into public.aios_tool_invocations
 (id,organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key,created_at)
values ('$INV','$ORG','$AGT','$T1','support.export_customer_data','support.export_customer_data',
 jsonb_build_object('scope','binding-race','format','csv'),'low','$REQ',gen_random_uuid(),'binding-race-'||gen_random_uuid(),now());
update public.aios_approvals set invocation_id=null where id =
 (select approval_id from public.aios_tool_invocations where id='$INV');
SQL
APPROVAL=$(q "select approval_id from public.aios_tool_invocations where id='$INV'")
[[ "$APPROVAL" =~ ^[0-9a-f-]{36}$ ]] || { echo "FAIL fixture approval missing"; exit 2; }

# B owns the original mission row. The lock-chain worker will read the old binding,
# then wait here before it can acquire the mission/task/invocation/approval chain.
(
  psql "$DB" -X -q -v ON_ERROR_STOP=1 >"$D/blocker.out" 2>"$D/blocker.err" <<SQL
begin;
select 1 from public.aios_missions where id='$M1' for no key update;
select pg_sleep(3);
update public.aios_tool_invocations set task_id='$T2' where id='$INV';
commit;
SQL
  echo $? >"$D/blocker.rc"
) &
BLOCKER=$!
i=0
until [ "$(q "select count(*) from pg_stat_activity where query like '%pg_sleep(3)%' and state='active'")" = 1 ]; do
  i=$((i+1)); [ "$i" -gt 100 ] && { echo "FAIL blocker did not acquire original mission row"; exit 2; }; sleep 0.05
done

(
  psql "$DB" -X -q -v ON_ERROR_STOP=1 >"$D/worker.out" 2>"$D/worker.err" -c "select private.aios_lock_approval_chain('$APPROVAL');"
  echo $? >"$D/worker.rc"
) &
WORKER=$!
i=0
until [ "$(q "select count(*) from pg_stat_activity where wait_event_type='Lock' and query like '%aios_lock_approval_chain%'")" = 1 ]; do
  i=$((i+1)); [ "$i" -gt 100 ] && { echo "FAIL chain-lock worker did not block on the original mission"; kill "$BLOCKER" "$WORKER" 2>/dev/null || true; exit 2; }; sleep 0.05
done

wait "$BLOCKER" || true
wait "$WORKER" || true
BRC=$(cat "$D/blocker.rc" 2>/dev/null || echo 99)
WRC=$(cat "$D/worker.rc" 2>/dev/null || echo 99)
if [ "$BRC" = 0 ]; then
  if [ "$WRC" = 0 ] || ! grep -q '40001' "$D/worker.err"; then
    echo "FAIL changed binding was not rejected after lock acquisition (worker rc=$WRC)"
    cat "$D/worker.err"
    exit 1
  fi
  echo "  PASS forced binding change committed while worker waited; worker rejected stale snapshot with 40001"
elif grep -q '42501\|immutable\|cannot change' "$D/blocker.err" && [ "$WRC" = 0 ]; then
  echo "  PASS database rejected invocation task_id mutation; post-lock worker completed against immutable binding"
else
  echo "FAIL unexpected blocker/worker outcome (blocker rc=$BRC worker rc=$WRC)"
  cat "$D/blocker.err" "$D/worker.err" 2>/dev/null || true
  exit 1
fi
echo "== approval-chain post-lock binding revalidation: PASS"
