-- Regression (additive; NOT part of the historical 46-case matrix): approval/task/agent organization binding.
-- Fixtures are created through normal paths with every trigger enabled; whole file is rolled back (throwaway CI database only).
-- Negative cases must fail closed with NO partial write and NO audit trace; positive cases must succeed and audit once.
begin;

insert into public.aios_organizations (id, name) values
  ('a7000000-0000-0000-0000-00000000000a', 'bind-org-a'),
  ('b7000000-0000-0000-0000-00000000000b', 'bind-org-b');
insert into public.aios_agents (id, organization_id, agent_key, name, role, authority) values
  ('a7100000-0000-0000-0000-000000000001', 'a7000000-0000-0000-0000-00000000000a', 'bind-agent-a', 'bind agent a', 'tester', '{"risk_level":"low","allowed_tools":[],"limits":{}}'),
  ('b7100000-0000-0000-0000-000000000001', 'b7000000-0000-0000-0000-00000000000b', 'bind-agent-b', 'bind agent b', 'tester', '{"risk_level":"low","allowed_tools":[],"limits":{}}');
insert into public.aios_tasks (id, organization_id, title, status) values
  ('a7200000-0000-0000-0000-000000000001', 'a7000000-0000-0000-0000-00000000000a', 'bind task a', 'blocked_pending_approval'),
  ('b7200000-0000-0000-0000-000000000001', 'b7000000-0000-0000-0000-00000000000b', 'bind task b', 'blocked_pending_approval');

do $$
declare
  org_a uuid := 'a7000000-0000-0000-0000-00000000000a'; org_b uuid := 'b7000000-0000-0000-0000-00000000000b';
  ag_a uuid := 'a7100000-0000-0000-0000-000000000001';  ag_b uuid := 'b7100000-0000-0000-0000-000000000001';
  tk_a uuid := 'a7200000-0000-0000-0000-000000000001';  tk_b uuid := 'b7200000-0000-0000-0000-000000000001';
  good uuid := 'a7300000-0000-0000-0000-000000000001';
  audit_a int; audit_b int; n int; failed boolean; msg text; t uuid; o uuid;
begin
  select count(*) into audit_a from public.aios_audit_events where organization_id = org_a;
  select count(*) into audit_b from public.aios_audit_events where organization_id = org_b;

  -- P1 positive: same-org agent + task binds and is audited exactly once.
  insert into public.aios_approvals (id, organization_id, agent_id, task_id, action, risk_level, status)
    values (good, org_a, ag_a, tk_a, 'bind', 'low', 'pending');
  select count(*) into n from public.aios_audit_events where approval_id = good and event_type = 'approval_changed';
  if n <> 1 then raise exception 'P1: expected exactly 1 approval audit event, got %', n; end if;
  select count(*) into audit_a from public.aios_audit_events where organization_id = org_a;

  -- N1: org A approval cannot authorize org B's task.
  failed := false;
  begin insert into public.aios_approvals (id, organization_id, agent_id, task_id, action, risk_level, status)
          values ('a7300000-0000-0000-0000-000000000002', org_a, null, tk_b, 'bind', 'low', 'pending');
  exception when others then failed := true; msg := sqlerrm; end;
  if not failed then raise exception 'N1: cross-org task binding was accepted'; end if;
  if msg not ilike '%organization%' then raise exception 'N1: rejected for an unexpected reason: %', msg; end if;

  -- N2: org A approval cannot use org B's agent (agent cannot be used to bypass task ownership).
  failed := false;
  begin insert into public.aios_approvals (id, organization_id, agent_id, task_id, action, risk_level, status)
          values ('a7300000-0000-0000-0000-000000000003', org_a, ag_b, tk_a, 'bind', 'low', 'pending');
  exception when others then failed := true; msg := sqlerrm; end;
  if not failed then raise exception 'N2: cross-org agent binding was accepted'; end if;
  if msg not ilike '%organization%' then raise exception 'N2: rejected for an unexpected reason: %', msg; end if;

  -- N3: org A approval with org A agent but org B task (mixed) is rejected.
  failed := false;
  begin insert into public.aios_approvals (id, organization_id, agent_id, task_id, action, risk_level, status)
          values ('a7300000-0000-0000-0000-000000000004', org_a, ag_a, tk_b, 'bind', 'low', 'pending');
  exception when others then failed := true; end;
  if not failed then raise exception 'N3: mixed agent/task binding was accepted'; end if;

  -- N4: re-pointing an existing pending approval at another org's task is rejected and the row is unchanged.
  failed := false;
  begin update public.aios_approvals set task_id = tk_b where id = good;
  exception when others then failed := true; end;
  if not failed then raise exception 'N4: re-binding to a foreign task was accepted'; end if;
  select task_id, organization_id into t, o from public.aios_approvals where id = good;
  if t <> tk_a or o <> org_a then raise exception 'N4: approval was modified despite rejection'; end if;

  -- N5: moving an existing approval to another organization is rejected.
  failed := false;
  begin update public.aios_approvals set organization_id = org_b where id = good;
  exception when others then failed := true; end;
  if not failed then raise exception 'N5: organization re-assignment was accepted'; end if;
  select organization_id into o from public.aios_approvals where id = good;
  if o <> org_a then raise exception 'N5: approval organization changed despite rejection'; end if;

  -- Fail-closed: nothing from N1-N5 persisted, nothing deleted, and no audit trace was written for any rejected operation.
  select count(*) into n from public.aios_approvals where id in
    ('a7300000-0000-0000-0000-000000000002','a7300000-0000-0000-0000-000000000003','a7300000-0000-0000-0000-000000000004');
  if n <> 0 then raise exception 'rejected approvals were persisted (%)', n; end if;
  if not exists (select 1 from public.aios_approvals where id = good) then raise exception 'valid approval was deleted'; end if;
  if (select count(*) from public.aios_audit_events where organization_id = org_a) <> audit_a then raise exception 'org A audit changed after rejected operations'; end if;
  if (select count(*) from public.aios_audit_events where organization_id = org_b) <> audit_b then raise exception 'org B audit changed after rejected operations'; end if;
  if exists (select 1 from public.aios_audit_events where organization_id = org_b and approval_id = good) then raise exception 'org A approval leaked into org B audit'; end if;

  -- Foreign task untouched.
  if (select status from public.aios_tasks where id = tk_b) <> 'blocked_pending_approval' then raise exception 'foreign task was modified'; end if;

  -- Integrity triggers still present and enabled (not weakened).
  select count(*) into n from pg_trigger where tgrelid = 'public.aios_approvals'::regclass and tgenabled = 'O'
    and tgname in ('trg_aios_validate_approval_integrity','trg_validate_agent_org','trg_validate_task_org','trg_aios_approval_status_guard','trg_aios_log_approval_audit');
  if n <> 5 then raise exception 'expected 5 enabled approval integrity triggers, found %', n; end if;
end $$;

rollback;
select 'ok: org/task binding regression' as result;
