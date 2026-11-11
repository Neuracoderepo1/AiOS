#!/usr/bin/env bash
# Real-PostgreSQL tied-timestamp regression for the shared approval invocation resolver.
set -euo pipefail
DB="$1"
ORG=ab020202-0000-4000-8000-000000000001
AGT=ab020202-0000-4000-8000-000000000002
REQ=ab020202-0000-4000-8000-000000000003
ADM=ab020202-0000-4000-8000-000000000004
q() { psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -c "$1"; }
cleanup() {
  q "begin; set local session_replication_role=replica;
     delete from public.aios_approvals where id in (
       select i.approval_id from public.aios_tool_invocations i join public.aios_tasks t on t.id=i.task_id
       where t.organization_id='$ORG' and t.title like 'tie-%' and i.approval_id is not null
     );
     delete from public.aios_tool_invocations where organization_id='$ORG';
     delete from public.aios_tasks where organization_id='$ORG';
     delete from public.aios_missions where organization_id='$ORG';
     delete from public.aios_contracts where agent_id='$AGT';
     delete from public.aios_agents where id='$AGT';
     delete from public.aios_organization_members where organization_id='$ORG';
     delete from public.aios_organizations where id='$ORG';
     delete from auth.users where id in ('$REQ','$ADM');
     commit;" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
q "insert into auth.users (id,aud,role,email) values ('$REQ','authenticated','authenticated','tie-req@example.test'),('$ADM','authenticated','authenticated','tie-adm@example.test') on conflict do nothing;
   insert into public.aios_organizations (id,name) values ('$ORG','approval-resolver-tie') on conflict do nothing;
   insert into public.aios_organization_members (organization_id,user_id,role) values ('$ORG','$REQ','member'),('$ORG','$ADM','admin') on conflict do nothing;
   insert into public.aios_agents (id,organization_id,agent_key,name,role,status,authority) values ('$AGT','$ORG','tie-resolver-agent','tie-resolver','tie-resolver','idle','{"risk_level":"medium","allowed_tools":["support.export_customer_data"],"limits":{}}') on conflict do nothing;
   insert into public.aios_contracts (organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active) values ('$ORG','$AGT',1,'medium','["support.export_customer_data"]','{}',true) on conflict (agent_id,version) do update set is_active=true;" >/dev/null
new_chain() {
  q "with m as (
       insert into public.aios_missions (organization_id,title,objective,status)
       values ('$ORG','tie-$1','resolver tie fixture','queued') returning id
     ), t as (
       insert into public.aios_tasks (organization_id,mission_id,assigned_agent_id,title,status)
       select '$ORG',id,'$AGT','tie-$1','queued' from m returning id
     ), i as (
       insert into public.aios_tool_invocations
         (organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key)
       select '$ORG','$AGT',id,'support.export_customer_data','support.export_customer_data',
         jsonb_build_object('scope','$1'),'low','$REQ',gen_random_uuid(),'tie-$1-'||gen_random_uuid() from t
       returning id,approval_id
     )
     select (select id from i)||'|'||(select approval_id from i)"
}
IFS='|' read -r I1 A1 <<<"$(new_chain one)"
IFS='|' read -r I2 A2 <<<"$(new_chain two)"
[[ "$I1" =~ ^[0-9a-f-]{36}$ && "$I2" =~ ^[0-9a-f-]{36}$ && "$A1" =~ ^[0-9a-f-]{36}$ && "$A2" =~ ^[0-9a-f-]{36}$ ]]
[[ "$A1" != "$A2" ]]
q "update public.aios_tool_invocations set approval_id='$A1',created_at='2026-11-01 00:00:00+00' where id='$I2';
   update public.aios_tool_invocations set created_at='2026-11-01 00:00:00+00' where id='$I1';
   update public.aios_approvals set invocation_id=null where id in ('$A1','$A2');
   delete from public.aios_approvals where id='$A2';" >/dev/null
MISSIONS=$(q "select count(distinct t.mission_id) from public.aios_tool_invocations i join public.aios_tasks t on t.id=i.task_id where i.approval_id='$A1'")
test "$MISSIONS" = 2
EXPECTED=$(q "select max(id)::text from public.aios_tool_invocations where approval_id='$A1'")
ACTUAL=$(q "select private.aios_resolve_approval_invocation('$A1')")
test "$ACTUAL" = "$EXPECTED"
EXPECTED_MISSION=$(q "select t.mission_id from public.aios_tool_invocations i join public.aios_tasks t on t.id=i.task_id where i.id='$EXPECTED'")
ACTUAL_MISSION=$(q "select t.mission_id from public.aios_tool_invocations i join public.aios_tasks t on t.id=i.task_id where i.id='$ACTUAL'")
test "$ACTUAL_MISSION" = "$EXPECTED_MISSION"
# Exercise both production paths against the exact same tied fixture.
q "select private.aios_prelock_approvals_batch(array['$A1']::uuid[]);
   select private.aios_lock_approval_chain('$A1');" >/dev/null
printf 'PASS: tied created_at reverse links select invocation %s in mission %s; both pre-lock and chain-lock paths execute\n' "$ACTUAL" "$ACTUAL_MISSION"
