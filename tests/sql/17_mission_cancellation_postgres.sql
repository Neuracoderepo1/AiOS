-- Real PostgreSQL cancellation contract: authenticated identity, membership authorization,
-- terminal no-op preservation, active cascade/audit, and repeat-call idempotency.
begin;

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('10000000-0000-4000-8000-000000000001','authenticated','authenticated','cancel-owner@aios.test','x',now(),'{}','{}',now(),now()),
  ('10000000-0000-4000-8000-000000000002','authenticated','authenticated','cancel-admin@aios.test','x',now(),'{}','{}',now(),now()),
  ('10000000-0000-4000-8000-000000000003','authenticated','authenticated','cancel-member@aios.test','x',now(),'{}','{}',now(),now()),
  ('10000000-0000-4000-8000-000000000004','authenticated','authenticated','cancel-outsider@aios.test','x',now(),'{}','{}',now(),now())
on conflict (id) do nothing;

insert into public.aios_organizations(id,name)
values ('50000000-0000-4000-8000-000000000001','Mission Cancellation SQL Test')
on conflict (id) do nothing;

insert into public.aios_agents(
  id, organization_id, agent_key, name, role, status, authority
) values (
  '50000000-0000-4000-8000-000000000009',
  '50000000-0000-4000-8000-000000000001',
  'cancel-contract-agent', 'Cancellation Contract Agent', 'test', 'idle',
  '{"risk_level":"low","allowed_tools":["support.export_customer_data"],"limits":{}}'::jsonb
) on conflict (id) do nothing;

insert into public.aios_contracts(
  organization_id, agent_id, version, risk_level, allowed_tools, limits, is_active
) values (
  '50000000-0000-4000-8000-000000000001',
  '50000000-0000-4000-8000-000000000009',
  1, 'low', '["support.export_customer_data"]'::jsonb, '{}'::jsonb, true
) on conflict (agent_id, version) do update
  set risk_level=excluded.risk_level,
      allowed_tools=excluded.allowed_tools,
      limits=excluded.limits,
      is_active=true;

insert into public.aios_organization_members(organization_id,user_id,role)
values
 ('50000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','owner'),
 ('50000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','admin'),
 ('50000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000003','member')
on conflict (organization_id,user_id) do update set role=excluded.role;

insert into public.aios_missions(id,organization_id,title,objective,status,completed_at)
values
 ('60000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','terminal failed','test','running',null),
 ('60000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000001','terminal cancelled','test','running',null),
 ('60000000-0000-4000-8000-000000000003','50000000-0000-4000-8000-000000000001','terminal completed','test','running',null),
 ('60000000-0000-4000-8000-000000000004','50000000-0000-4000-8000-000000000001','terminal expired','test','running',null),
 ('60000000-0000-4000-8000-000000000005','50000000-0000-4000-8000-000000000001','terminal succeeded','test','succeeded',now()),
 ('60000000-0000-4000-8000-000000000006','50000000-0000-4000-8000-000000000001','owner active','test','running',null),
 ('60000000-0000-4000-8000-000000000007','50000000-0000-4000-8000-000000000001','admin active','test','queued',null);

insert into public.aios_tasks(id,organization_id,mission_id,assigned_agent_id,title,status)
values
 ('70000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000009','task failed','failed'),
 ('70000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000009','task cancelled','cancelled'),
 ('70000000-0000-4000-8000-000000000003','50000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000003','50000000-0000-4000-8000-000000000009','task completed','completed'),
 ('70000000-0000-4000-8000-000000000004','50000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000004','50000000-0000-4000-8000-000000000009','task expired','failed'),
 ('70000000-0000-4000-8000-000000000005','50000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000005','50000000-0000-4000-8000-000000000009','task succeeded','completed'),
 ('70000000-0000-4000-8000-000000000006','50000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000006','50000000-0000-4000-8000-000000000009','task owner active','queued'),
 ('70000000-0000-4000-8000-000000000007','50000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000007','50000000-0000-4000-8000-000000000009','task admin active','queued');

insert into public.aios_approvals(id,organization_id,task_id,action,risk_level,status)
values
 ('80000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','70000000-0000-4000-8000-000000000001','test','low','pending'),
 ('80000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000001','70000000-0000-4000-8000-000000000002','test','low','pending'),
 ('80000000-0000-4000-8000-000000000003','50000000-0000-4000-8000-000000000001','70000000-0000-4000-8000-000000000003','test','low','pending'),
 ('80000000-0000-4000-8000-000000000004','50000000-0000-4000-8000-000000000001','70000000-0000-4000-8000-000000000004','test','low','pending'),
 ('80000000-0000-4000-8000-000000000005','50000000-0000-4000-8000-000000000001','70000000-0000-4000-8000-000000000005','test','low','expired'),
 ('80000000-0000-4000-8000-000000000006','50000000-0000-4000-8000-000000000001','70000000-0000-4000-8000-000000000006','test','low','pending'),
 ('80000000-0000-4000-8000-000000000007','50000000-0000-4000-8000-000000000001','70000000-0000-4000-8000-000000000007','test','low','pending');

insert into public.aios_tool_invocations(
  id, organization_id, agent_id, task_id, tool_name, tool_key, arguments,
  risk_level, requested_by, request_id, idempotency_key, status, approval_id
)
values
 ('90000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000009','70000000-0000-4000-8000-000000000001','support.export_customer_data','support.export_customer_data','{"scope":"cancel-test","format":"csv"}','low','10000000-0000-4000-8000-000000000001',gen_random_uuid(),'cancel-test-1','approved','80000000-0000-4000-8000-000000000001'),
 ('90000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000009','70000000-0000-4000-8000-000000000002','support.export_customer_data','support.export_customer_data','{"scope":"cancel-test","format":"csv"}','low','10000000-0000-4000-8000-000000000001',gen_random_uuid(),'cancel-test-2','approved','80000000-0000-4000-8000-000000000002'),
 ('90000000-0000-4000-8000-000000000003','50000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000009','70000000-0000-4000-8000-000000000003','support.export_customer_data','support.export_customer_data','{"scope":"cancel-test","format":"csv"}','low','10000000-0000-4000-8000-000000000001',gen_random_uuid(),'cancel-test-3','approved','80000000-0000-4000-8000-000000000003'),
 ('90000000-0000-4000-8000-000000000004','50000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000009','70000000-0000-4000-8000-000000000004','support.export_customer_data','support.export_customer_data','{"scope":"cancel-test","format":"csv"}','low','10000000-0000-4000-8000-000000000001',gen_random_uuid(),'cancel-test-4','approved','80000000-0000-4000-8000-000000000004'),
 ('90000000-0000-4000-8000-000000000005','50000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000009','70000000-0000-4000-8000-000000000005','support.export_customer_data','support.export_customer_data','{"scope":"cancel-test","format":"csv"}','low','10000000-0000-4000-8000-000000000001',gen_random_uuid(),'cancel-test-5','cancelled','80000000-0000-4000-8000-000000000005'),
 ('90000000-0000-4000-8000-000000000006','50000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000009','70000000-0000-4000-8000-000000000006','support.export_customer_data','support.export_customer_data','{"scope":"cancel-test","format":"csv"}','low','10000000-0000-4000-8000-000000000001',gen_random_uuid(),'cancel-test-6','approved','80000000-0000-4000-8000-000000000006'),
 ('90000000-0000-4000-8000-000000000007','50000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000009','70000000-0000-4000-8000-000000000007','support.export_customer_data','support.export_customer_data','{"scope":"cancel-test","format":"csv"}','low','10000000-0000-4000-8000-000000000001',gen_random_uuid(),'cancel-test-7','approved','80000000-0000-4000-8000-000000000007');

-- Create dependent fixtures while their parent missions are active. The task gate
-- rejects live task writes under terminal parents. The succeeded fixture is seeded
-- directly terminal with terminal children, so this test does not invent a new transition.
-- Transition the other four parents only after their dependent fixtures are created.
update public.aios_missions
   set status = case id
     when '60000000-0000-4000-8000-000000000001' then 'failed'
     when '60000000-0000-4000-8000-000000000002' then 'cancelled'
     when '60000000-0000-4000-8000-000000000003' then 'completed'
     when '60000000-0000-4000-8000-000000000004' then 'expired'
   end
 where id in (
   '60000000-0000-4000-8000-000000000001',
   '60000000-0000-4000-8000-000000000002',
   '60000000-0000-4000-8000-000000000003',
   '60000000-0000-4000-8000-000000000004'
 );


-- A succeeded mission is terminal without cancelling already-completed work.
-- Residual approved invocations and pending approvals must be closed, and live
-- task creation under the succeeded parent must fail closed.
do $succeeded_integrity$
declare
  v_denied boolean := false;
begin
  if (select status from public.aios_tasks
      where id='70000000-0000-4000-8000-000000000005') <> 'completed' then
    raise exception 'succeeded mission did not preserve its completed task';
  end if;
  if (select status from public.aios_tool_invocations
      where id='90000000-0000-4000-8000-000000000005') <> 'cancelled' then
    raise exception 'succeeded mission retained a live approved invocation';
  end if;
  if (select status from public.aios_approvals
      where id='80000000-0000-4000-8000-000000000005') <> 'expired' then
    raise exception 'succeeded mission retained a pending approval';
  end if;
  if exists (
    select 1 from public.aios_tasks
     where mission_id='60000000-0000-4000-8000-000000000005'
       and status in ('queued','assigned','ready','running','approved','blocked_pending_approval')
  ) then
    raise exception 'succeeded mission retained a live task';
  end if;
  if exists (
    select 1 from public.aios_tool_invocations i
    join public.aios_tasks t on t.id=i.task_id
     where t.mission_id='60000000-0000-4000-8000-000000000005'
       and i.status in ('requires_approval','approved')
  ) then
    raise exception 'succeeded mission retained a live invocation';
  end if;
  if exists (
    select 1 from public.aios_approvals ap
    join public.aios_tasks t on t.id=ap.task_id
     where t.mission_id='60000000-0000-4000-8000-000000000005'
       and ap.status='pending'
  ) then
    raise exception 'succeeded mission retained a pending approval';
  end if;

  begin
    insert into public.aios_tasks(
      id,organization_id,mission_id,assigned_agent_id,title,status
    ) values (
      '70000000-0000-4000-8000-000000000008',
      '50000000-0000-4000-8000-000000000001',
      '60000000-0000-4000-8000-000000000005',
      '50000000-0000-4000-8000-000000000009',
      'forbidden live task under succeeded mission',
      'queued'
    );
  exception when insufficient_privilege then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'task gate allowed a live task under a succeeded mission';
  end if;
end
$succeeded_integrity$;

set local role authenticated;

do $$
declare
  v_ids uuid[] := array[
    '60000000-0000-4000-8000-000000000001'::uuid,
    '60000000-0000-4000-8000-000000000002'::uuid,
    '60000000-0000-4000-8000-000000000003'::uuid,
    '60000000-0000-4000-8000-000000000004'::uuid,
    '60000000-0000-4000-8000-000000000005'::uuid
  ];
  v_task_ids uuid[] := array[
    '70000000-0000-4000-8000-000000000001'::uuid,
    '70000000-0000-4000-8000-000000000002'::uuid,
    '70000000-0000-4000-8000-000000000003'::uuid,
    '70000000-0000-4000-8000-000000000004'::uuid,
    '70000000-0000-4000-8000-000000000005'::uuid
  ];
  v_inv_ids uuid[] := array[
    '90000000-0000-4000-8000-000000000001'::uuid,
    '90000000-0000-4000-8000-000000000002'::uuid,
    '90000000-0000-4000-8000-000000000003'::uuid,
    '90000000-0000-4000-8000-000000000004'::uuid,
    '90000000-0000-4000-8000-000000000005'::uuid
  ];
  v_ap_ids uuid[] := array[
    '80000000-0000-4000-8000-000000000001'::uuid,
    '80000000-0000-4000-8000-000000000002'::uuid,
    '80000000-0000-4000-8000-000000000003'::uuid,
    '80000000-0000-4000-8000-000000000004'::uuid,
    '80000000-0000-4000-8000-000000000005'::uuid
  ];
  i integer;
  v_before jsonb;
  v_after jsonb;
  v_task_before jsonb;
  v_inv_before jsonb;
  v_ap_before jsonb;
  v_audit_before bigint;
  v_denied boolean;
  v_result jsonb;
begin
  -- A normal member and an unrelated user cannot cancel, even though the
  -- RPC has no actor parameter that either caller could forge.
  perform set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',true);
  v_denied := false;
  begin
    perform public.aios_cancel_mission('60000000-0000-4000-8000-000000000006');
  exception when insufficient_privilege then
    v_denied := true;
  end;
  if not v_denied then raise exception 'ordinary member unexpectedly cancelled mission'; end if;

  perform set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000004',true);
  v_denied := false;
  begin
    perform public.aios_cancel_mission('60000000-0000-4000-8000-000000000006');
  exception when insufficient_privilege then
    v_denied := true;
  end;
  if not v_denied then raise exception 'unrelated actor unexpectedly cancelled mission'; end if;

  -- Every terminal state returns already_terminal twice and preserves the
  -- mission, task, invocation, approval, and cancellation-audit count.
  perform set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
  for i in 1..array_length(v_ids,1) loop
    select to_jsonb(m) into v_before from public.aios_missions m where m.id=v_ids[i];
    select to_jsonb(t) into v_task_before from public.aios_tasks t where t.id=v_task_ids[i];
    select to_jsonb(x) into v_inv_before from public.aios_tool_invocations x where x.id=v_inv_ids[i];
    select to_jsonb(a) into v_ap_before from public.aios_approvals a where a.id=v_ap_ids[i];
    select count(*) into v_audit_before from public.aios_audit_events
      where organization_id='50000000-0000-4000-8000-000000000001'
        and event_type='mission_cancellation_requested';

    v_result := public.aios_cancel_mission(v_ids[i]);
    if v_result->>'outcome' <> 'already_terminal' then
      raise exception 'terminal mission % first result was %',v_ids[i],v_result;
    end if;
    v_result := public.aios_cancel_mission(v_ids[i]);
    if v_result->>'outcome' <> 'already_terminal' then
      raise exception 'terminal mission % repeat result was %',v_ids[i],v_result;
    end if;

    select to_jsonb(m) into v_after from public.aios_missions m where m.id=v_ids[i];
    if v_after is distinct from v_before then raise exception 'terminal mission row mutated: %',v_ids[i]; end if;
    select to_jsonb(t) into v_after from public.aios_tasks t where t.id=v_task_ids[i];
    if v_after is distinct from v_task_before then raise exception 'terminal task mutated: %',v_task_ids[i]; end if;
    select to_jsonb(x) into v_after from public.aios_tool_invocations x where x.id=v_inv_ids[i];
    if v_after is distinct from v_inv_before then raise exception 'terminal invocation mutated: %',v_ids[i]; end if;
    select to_jsonb(a) into v_after from public.aios_approvals a where a.id=v_ap_ids[i];
    if v_after is distinct from v_ap_before then raise exception 'terminal approval mutated: %',v_ids[i]; end if;
    if (select count(*) from public.aios_audit_events
        where organization_id='50000000-0000-4000-8000-000000000001'
          and event_type='mission_cancellation_requested') <> v_audit_before then
      raise exception 'terminal no-op emitted cancellation audit event: %',v_ids[i];
    end if;
  end loop;

  -- Owner cancellation cascades exactly once and writes one cancellation audit.
  select count(*) into v_audit_before from public.aios_audit_events
    where organization_id='50000000-0000-4000-8000-000000000001'
      and event_type='mission_cancellation_requested';
  v_result := public.aios_cancel_mission('60000000-0000-4000-8000-000000000006');
  if v_result->>'outcome' <> 'cancelled' then raise exception 'owner cancellation failed: %',v_result; end if;
  v_result := public.aios_cancel_mission('60000000-0000-4000-8000-000000000006');
  if v_result->>'outcome' <> 'already_terminal' then raise exception 'owner repeat was not idempotent: %',v_result; end if;
  if (select status from public.aios_missions where id='60000000-0000-4000-8000-000000000006') <> 'cancelled'
     or (select status from public.aios_tasks where id='70000000-0000-4000-8000-000000000006') <> 'cancelled'
     or (select status from public.aios_tool_invocations where id='90000000-0000-4000-8000-000000000006') <> 'cancelled'
     or (select status from public.aios_approvals where id='80000000-0000-4000-8000-000000000006') <> 'expired' then
    raise exception 'owner cancellation did not cascade to task/invocation/approval';
  end if;
  if (select count(*) from public.aios_audit_events
      where organization_id='50000000-0000-4000-8000-000000000001'
        and event_type='mission_cancellation_requested') <> v_audit_before+1 then
    raise exception 'owner cancellation must emit exactly one cancellation audit event';
  end if;

  -- Admin is also authorized by the same authenticated-identity contract.
  perform set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
  v_result := public.aios_cancel_mission('60000000-0000-4000-8000-000000000007');
  if v_result->>'outcome' <> 'cancelled' then raise exception 'admin cancellation failed: %',v_result; end if;
end
$$;

reset role;
rollback;

select 'ok: real PostgreSQL mission cancellation contract' as result;
