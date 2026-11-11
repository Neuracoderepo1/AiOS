#!/usr/bin/env bash
# Disposable real-PostgreSQL regression. All fixtures and audit events roll back in one session.
set -euo pipefail
DB="$1"
psql "$DB" -X -v ON_ERROR_STOP=1 <<'SQL'
\set ON_ERROR_STOP on
begin;
select gen_random_uuid() as org_id \gset
select gen_random_uuid() as agent_id \gset
select gen_random_uuid() as requester_id \gset
select gen_random_uuid() as admin_id \gset
\set tied_at '2026-11-01 00:00:00+00'

insert into auth.users (id,aud,role,email)
values (:'requester_id','authenticated','authenticated','tie-req-'||:'requester_id'||'@example.test'),
       (:'admin_id','authenticated','authenticated','tie-adm-'||:'admin_id'||'@example.test');
insert into public.aios_organizations(id,name) values (:'org_id','approval-resolver-tie');
insert into public.aios_organization_members(organization_id,user_id,role)
values (:'org_id',:'requester_id','member'),(:'org_id',:'admin_id','admin');
insert into public.aios_agents(id,organization_id,agent_key,name,role,status,authority)
values (:'agent_id',:'org_id','tie-resolver-agent','tie-resolver','tie-resolver','idle',
  jsonb_build_object('risk_level','medium','allowed_tools',jsonb_build_array('support.export_customer_data'),'limits','{}'::jsonb));
insert into public.aios_contracts(organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active)
values (:'org_id',:'agent_id',1,'medium',jsonb_build_array('support.export_customer_data'),'{}'::jsonb,true);

with m as (
  insert into public.aios_missions(organization_id,title,objective,status)
  values (:'org_id','tie-one','resolver tie fixture','queued') returning id
), t as (
  insert into public.aios_tasks(organization_id,mission_id,assigned_agent_id,title,status)
  select :'org_id',id,:'agent_id','tie-one','queued' from m returning id
), i as (
  insert into public.aios_tool_invocations
    (organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key,created_at)
  select :'org_id',:'agent_id',id,'support.export_customer_data','support.export_customer_data',
    jsonb_build_object('scope','a','format','csv'),'low',:'requester_id',gen_random_uuid(),'tie-one-'||gen_random_uuid(),:'tied_at'::timestamptz
  from t returning id,approval_id
)
select id as invocation_one, approval_id as approval_one from i \gset

with m as (
  insert into public.aios_missions(organization_id,title,objective,status)
  values (:'org_id','tie-two','resolver tie fixture','queued') returning id
), t as (
  insert into public.aios_tasks(organization_id,mission_id,assigned_agent_id,title,status)
  select :'org_id',id,:'agent_id','tie-two','queued' from m returning id
), i as (
  insert into public.aios_tool_invocations
    (organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key,created_at)
  select :'org_id',:'agent_id',id,'support.export_customer_data','support.export_customer_data',
    jsonb_build_object('scope','b','format','csv'),'low',:'requester_id',gen_random_uuid(),'tie-two-'||gen_random_uuid(),:'tied_at'::timestamptz
  from t returning id,approval_id
)
select id as invocation_two, approval_id as approval_two from i \gset

-- Force two reverse-linked invocations from distinct missions to share one approval.
update public.aios_tool_invocations set approval_id=:'approval_one' where id=:'invocation_two';
update public.aios_approvals set invocation_id=null where id in (:'approval_one',:'approval_two');

select (count(distinct t.mission_id)=2) as fixture_valid
from public.aios_tool_invocations i join public.aios_tasks t on t.id=i.task_id
where i.approval_id=:'approval_one' \gset
\if :fixture_valid
\else
  \echo 'FAIL: fixture did not create two mission chains'
  \quit 1
\endif

select (
  private.aios_resolve_approval_invocation(:'approval_one'::uuid)::text =
  (select id::text from public.aios_tool_invocations
   where approval_id=:'approval_one' order by created_at desc,id desc limit 1)
) as resolver_valid \gset
\if :resolver_valid
\else
  \echo 'FAIL: resolver did not use created_at DESC, id DESC'
  \quit 1
\endif

select private.aios_prelock_approvals_batch(array[:'approval_one'::uuid]);
select private.aios_lock_approval_chain(:'approval_one'::uuid);
\echo 'PASS: tied reverse links resolve deterministically; both production lock paths execute'
rollback;
SQL
