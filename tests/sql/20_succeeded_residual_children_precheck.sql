-- F-40-07 follow-up: pre-existing 'succeeded' missions with residual live tasks, invocations or
-- pending approvals are not swept by the cascade (it fires only on a status change). The migration
-- therefore aborts over such rows via private.aios_assert_no_residual_succeeded_children().
-- Legacy-shaped fixtures are inserted under session_replication_role = replica ONLY inside this
-- rolled-back transaction (same convention as tests/sql/08 and 09); the check itself runs with
-- triggers enabled.
begin;

set local session_replication_role = replica;
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('20000000-0000-4000-8000-000000000001','authenticated','authenticated','residual-owner@aios.test','x',now(),'{}','{}',now(),now())
on conflict (id) do nothing;
insert into public.aios_organizations (id, name) values ('20100000-0000-4000-8000-000000000001','succeeded-residual-org');
insert into public.aios_agents (id, organization_id, agent_key, name, role, status, authority)
values ('20200000-0000-4000-8000-000000000001','20100000-0000-4000-8000-000000000001','residual-agent','residual','test','idle',
        '{"risk_level":"low","allowed_tools":["support.export_customer_data"],"limits":{}}'::jsonb);
-- Clean baseline: a succeeded mission whose only child is a completed task with terminal records.
insert into public.aios_missions (id, organization_id, title, objective, status, completed_at)
values ('20300000-0000-4000-8000-000000000001','20100000-0000-4000-8000-000000000001','clean','t','succeeded',now());
insert into public.aios_tasks (id, organization_id, mission_id, assigned_agent_id, title, status)
values ('20400000-0000-4000-8000-000000000001','20100000-0000-4000-8000-000000000001','20300000-0000-4000-8000-000000000001','20200000-0000-4000-8000-000000000001','clean task','completed');
insert into public.aios_approvals (id, organization_id, task_id, action, risk_level, status)
values ('20500000-0000-4000-8000-000000000001','20100000-0000-4000-8000-000000000001','20400000-0000-4000-8000-000000000001','test','low','expired');
insert into public.aios_tool_invocations (id, organization_id, agent_id, task_id, tool_name, tool_key, arguments, risk_level, requested_by, request_id, idempotency_key, status)
values ('20600000-0000-4000-8000-000000000001','20100000-0000-4000-8000-000000000001','20200000-0000-4000-8000-000000000001','20400000-0000-4000-8000-000000000001',
        'support.export_customer_data','support.export_customer_data','{"scope":"residual"}','low','20000000-0000-4000-8000-000000000001',gen_random_uuid(),'residual-clean','cancelled');
set local session_replication_role = origin;

do $precheck$
declare
  v_err text; v_state text;
  v_case text;
begin
  -- 0. The function is not executable by any client role.
  if has_function_privilege('anon','private.aios_assert_no_residual_succeeded_children()','execute')
     or has_function_privilege('authenticated','private.aios_assert_no_residual_succeeded_children()','execute')
     or has_function_privilege('service_role','private.aios_assert_no_residual_succeeded_children()','execute') then
    raise exception 'precheck function is executable by a client role';
  end if;

  -- 1. Clean data (terminal children only) passes.
  perform private.aios_assert_no_residual_succeeded_children();

  -- 2..4. Each predicate, in turn, makes the check fail closed with SQLSTATE 55000 and its own count.
  foreach v_case in array array['task','invocation','approval'] loop
    set local session_replication_role = replica;
    if v_case = 'task' then
      insert into public.aios_tasks (id, organization_id, mission_id, assigned_agent_id, title, status)
      values ('20400000-0000-4000-8000-0000000000ff','20100000-0000-4000-8000-000000000001','20300000-0000-4000-8000-000000000001','20200000-0000-4000-8000-000000000001','residual live task','queued');
    elsif v_case = 'invocation' then
      insert into public.aios_tool_invocations (id, organization_id, agent_id, task_id, tool_name, tool_key, arguments, risk_level, requested_by, request_id, idempotency_key, status)
      values ('20600000-0000-4000-8000-0000000000ff','20100000-0000-4000-8000-000000000001','20200000-0000-4000-8000-000000000001','20400000-0000-4000-8000-000000000001',
              'support.export_customer_data','support.export_customer_data','{"scope":"residual"}','low','20000000-0000-4000-8000-000000000001',gen_random_uuid(),'residual-live','approved');
    else
      insert into public.aios_approvals (id, organization_id, task_id, action, risk_level, status)
      values ('20500000-0000-4000-8000-0000000000ff','20100000-0000-4000-8000-000000000001','20400000-0000-4000-8000-000000000001','test','low','pending');
    end if;
    set local session_replication_role = origin;

    v_err := null; v_state := null;
    begin
      perform private.aios_assert_no_residual_succeeded_children();
    exception when others then
      v_err := sqlerrm; v_state := sqlstate;
    end;
    if v_err is null then raise exception 'precheck passed over a residual live % under a succeeded mission', v_case; end if;
    if v_state <> '55000' then raise exception 'precheck (%) failed with SQLSTATE % instead of 55000: %', v_case, v_state, v_err; end if;
    if v_err not like 'succeeded missions have residual live children (tasks=%, invocations=%, approvals=%)%' then
      raise exception 'precheck (%) message unexpected: %', v_case, v_err;
    end if;
    if (v_case = 'task' and v_err not like '%tasks=1,%')
       or (v_case = 'invocation' and v_err not like '%invocations=1,%')
       or (v_case = 'approval' and v_err not like '%approvals=1)%') then
      raise exception 'precheck (%) reported the wrong predicate: %', v_case, v_err;
    end if;

    set local session_replication_role = replica;
    delete from public.aios_tool_invocations where id = '20600000-0000-4000-8000-0000000000ff';
    delete from public.aios_approvals where id = '20500000-0000-4000-8000-0000000000ff';
    delete from public.aios_tasks where id = '20400000-0000-4000-8000-0000000000ff';
    set local session_replication_role = origin;
    perform private.aios_assert_no_residual_succeeded_children();
  end loop;

  -- 5. Live children under NON-succeeded missions are out of scope for this check.
  set local session_replication_role = replica;
  insert into public.aios_missions (id, organization_id, title, objective, status)
  values ('20300000-0000-4000-8000-000000000002','20100000-0000-4000-8000-000000000001','active','t','running');
  insert into public.aios_tasks (id, organization_id, mission_id, assigned_agent_id, title, status)
  values ('20400000-0000-4000-8000-000000000002','20100000-0000-4000-8000-000000000001','20300000-0000-4000-8000-000000000002','20200000-0000-4000-8000-000000000001','active live task','running');
  set local session_replication_role = origin;
  perform private.aios_assert_no_residual_succeeded_children();
end
$precheck$;

rollback;

select 'ok: succeeded residual-children precondition fails closed' as result;
