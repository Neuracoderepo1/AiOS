-- Regression: the canonical approval-expiry job must isolate invalid records instead of aborting the batch.
--
-- Fixtures reproduce LEGACY production state (rows written before the integrity guards existed), which the guards would
-- refuse to create today. They are therefore inserted with session_replication_role = replica, ONLY inside this transaction on
-- a throwaway local database, and the role is switched back to origin BEFORE the job runs, so the job and every integrity
-- trigger execute exactly as in production. The whole file is rolled back. Nothing here disables a trigger in production.
begin;

set local session_replication_role = replica;

insert into public.aios_organizations (id, name) values
  ('a0000000-0000-0000-0000-00000000000a', 'conv-test-org-a'),
  ('b0000000-0000-0000-0000-00000000000b', 'conv-test-org-b');

insert into public.aios_agents (id, organization_id, agent_key, name, role, authority) values
  ('b1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-00000000000b', 'conv-agent-b', 'conv agent b', 'tester',
   '{"risk_level":"low","allowed_tools":[],"limits":{}}');

insert into public.aios_tasks (id, organization_id, title, status) values
  ('a2000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-00000000000a', 'conv t1 valid legacy',   'blocked_pending_approval'),
  ('a2000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-00000000000a', 'conv t7 valid expiring', 'blocked_pending_approval'),
  ('b2000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-00000000000b', 'conv t3 foreign org',    'blocked_pending_approval');

-- Approvals. apv4 is the OLDEST, so under the old behaviour it is processed first and aborts the whole batch.
insert into public.aios_approvals (id, organization_id, agent_id, task_id, invocation_id, action, risk_level, status, expires_at, created_at) values
  ('a3000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-00000000000a', 'b1000000-0000-0000-0000-000000000001', null, null,                                   'conv', 'low', 'pending', null, now() - interval '10 days'), -- agent in another org
  ('a3000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-00000000000a', null, null, null,                                                                     'conv', 'low', 'pending', null, now() - interval '9 days'),  -- legacy link to another org's invocation
  ('a3000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-00000000000a', null, null, 'b4000000-0000-0000-0000-000000000005',                                   'conv', 'low', 'pending', null, now() - interval '8 days'),  -- direct invocation in another org
  ('a3000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-00000000000a', null, null, null,                                                                     'conv', 'low', 'pending', null, now() - interval '3 days'),  -- valid legacy, linked via invocation.approval_id
  ('a3000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-00000000000a', null, null, null,                                                                     'conv', 'low', 'pending', null, now() - interval '3 days'),  -- valid orphan
  ('a3000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-00000000000a', null, null, null,                                                                     'conv', 'low', 'pending', null, now() - interval '3 days'),  -- in flight
  ('a3000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-00000000000a', null, 'a2000000-0000-0000-0000-000000000007', 'a4000000-0000-0000-0000-000000000007', 'conv', 'low', 'pending', now() - interval '1 hour', now() - interval '2 days'); -- valid, explicit expiry

insert into public.aios_tool_invocations (id, organization_id, task_id, tool_name, status, approval_id) values
  ('a4000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000001', 'conv.tool', 'requires_approval', 'a3000000-0000-0000-0000-000000000001'),
  ('b4000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-00000000000b', 'b2000000-0000-0000-0000-000000000003', 'conv.tool', 'requires_approval', 'a3000000-0000-0000-0000-000000000003'),
  ('b4000000-0000-0000-0000-000000000005', 'b0000000-0000-0000-0000-00000000000b', null,                                   'conv.tool', 'requires_approval', null),
  ('a4000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-00000000000a', null,                                   'conv.tool', 'approved',          'a3000000-0000-0000-0000-000000000006'),
  ('a4000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000007', 'conv.tool', 'requires_approval', 'a3000000-0000-0000-0000-000000000007');

-- Pre-existing disposition history for the mismatched approvals (as the earlier migration wrote it).
insert into public.aios_backlog_dispositions (organization_id, entity_type, entity_id, classification, disposition, rationale, decided_by) values
  ('a0000000-0000-0000-0000-00000000000a', 'approval', 'a3000000-0000-0000-0000-000000000003', 'untethered_fixture_approval', 'expire_via_canonical_job', 'fixture: earlier disposition', 'migration:20261101210000');

set local session_replication_role = origin;

create temp table _conv_run (n int, r jsonb);
insert into _conv_run select 1, private.aios_expire_stale_approvals();
insert into _conv_run select 2, private.aios_expire_stale_approvals();

do $$
declare
  r1 jsonb := (select r from _conv_run where n = 1);
  r2 jsonb := (select r from _conv_run where n = 2);
  st text; n int;
  invalid uuid[] := array['a3000000-0000-0000-0000-000000000004','a3000000-0000-0000-0000-000000000003','a3000000-0000-0000-0000-000000000005']::uuid[];
begin
  -- 1. The invalid records did not abort the batch: eligible legacy approvals converged.
  select status into st from public.aios_approvals where id = 'a3000000-0000-0000-0000-000000000001';
  if st <> 'expired' then raise exception 'valid legacy approval not expired (%): batch was aborted. report=%', st, r1; end if;
  select status into st from public.aios_approvals where id = 'a3000000-0000-0000-0000-000000000002';
  if st <> 'expired' then raise exception 'orphan approval not expired (%)', st; end if;
  select status into st from public.aios_approvals where id = 'a3000000-0000-0000-0000-000000000007';
  if st <> 'expired' then raise exception 'explicit-expiry approval not expired (%)', st; end if;

  -- 2. Linked invocations / tasks transitioned appropriately.
  select status into st from public.aios_tool_invocations where id = 'a4000000-0000-0000-0000-000000000001';
  if st <> 'expired' then raise exception 'legacy-linked invocation not expired (%)', st; end if;
  select status into st from public.aios_tool_invocations where id = 'a4000000-0000-0000-0000-000000000007';
  if st <> 'expired' then raise exception 'direct-linked invocation not expired (%)', st; end if;
  select status into st from public.aios_tasks where id = 'a2000000-0000-0000-0000-000000000001';
  if st <> 'expired' then raise exception 'task of legacy invocation not expired (%)', st; end if;
  select status into st from public.aios_tasks where id = 'a2000000-0000-0000-0000-000000000007';
  if st <> 'expired' then raise exception 'task of direct invocation not expired (%)', st; end if;

  -- 3. In-flight approval untouched.
  select status into st from public.aios_approvals where id = 'a3000000-0000-0000-0000-000000000006';
  if st <> 'pending' then raise exception 'in-flight approval was changed (%)', st; end if;
  select status into st from public.aios_tool_invocations where id = 'a4000000-0000-0000-0000-000000000006';
  if st <> 'approved' then raise exception 'in-flight invocation was changed (%)', st; end if;

  -- 4. Invalid records protected: approval, foreign invocation and foreign task all unchanged (tenant isolation).
  if exists (select 1 from public.aios_approvals where id = any(invalid) and status <> 'pending') then
    raise exception 'an invalid-binding approval was transitioned';
  end if;
  select status into st from public.aios_tool_invocations where id = 'b4000000-0000-0000-0000-000000000003';
  if st <> 'requires_approval' then raise exception 'cross-tenant invocation was modified (%)', st; end if;
  select status into st from public.aios_tool_invocations where id = 'b4000000-0000-0000-0000-000000000005';
  if st <> 'requires_approval' then raise exception 'cross-tenant direct invocation was modified (%)', st; end if;
  select status into st from public.aios_tasks where id = 'b2000000-0000-0000-0000-000000000003';
  if st <> 'blocked_pending_approval' then raise exception 'cross-tenant task was modified (%)', st; end if;

  -- 5. Report: counts and per-record reasons.
  if (r1->>'skipped_invalid_binding')::int <> 3 then raise exception 'expected 3 invalid bindings reported, got %', r1; end if;
  if (r1->>'skipped_failed')::int <> 0 then raise exception 'unexpected transition failures: %', r1; end if;
  if (r1->>'approvals_expired')::int <> 2 or (r1->>'orphan_approvals_expired')::int <> 1 then raise exception 'wrong expiry counts: %', r1; end if;
  if (r1->>'skipped_in_flight')::int <> 1 then raise exception 'in-flight skip not reported: %', r1; end if;
  if jsonb_array_length(r1->'skipped_records') <> 3 then raise exception 'skipped_records wrong: %', r1; end if;
  if not exists (select 1 from jsonb_array_elements(r1->'skipped_records') e where e->>'reason' = 'agent_org_mismatch')
     or not exists (select 1 from jsonb_array_elements(r1->'skipped_records') e where e->>'reason' = 'linked_invocation_org_mismatch')
     or not exists (select 1 from jsonb_array_elements(r1->'skipped_records') e where e->>'reason' = 'invocation_org_mismatch') then
    raise exception 'defect reasons not reported as expected: %', r1->'skipped_records';
  end if;

  -- 6. Idempotent: second run converges nothing new and appends no duplicate dispositions.
  if (r2->>'approvals_expired')::int <> 0 or (r2->>'orphan_approvals_expired')::int <> 0 then raise exception 'second run was not a no-op: %', r2; end if;
  if (r2->>'skipped_invalid_binding')::int <> 3 then raise exception 'invalid records not re-reported on second run: %', r2; end if;
  select count(*) into n from public.aios_backlog_dispositions where entity_type = 'approval' and entity_id = any(invalid) and disposition = 'manual_review';
  if n <> 3 then raise exception 'expected exactly 3 manual_review dispositions after two runs, got %', n; end if;

  -- 7. Append-only: the earlier disposition is preserved and the effective disposition is manual_review.
  if not exists (select 1 from public.aios_backlog_dispositions where entity_id = 'a3000000-0000-0000-0000-000000000003'
                 and disposition = 'expire_via_canonical_job' and decided_by = 'migration:20261101210000') then
    raise exception 'prior disposition history was not preserved';
  end if;
  select disposition into st from public.aios_backlog_effective_dispositions where entity_type = 'approval' and entity_id = 'a3000000-0000-0000-0000-000000000003';
  if st is distinct from 'manual_review' then raise exception 'effective disposition is %, expected manual_review', st; end if;
  begin
    update public.aios_backlog_dispositions set rationale = 'tamper' where entity_id = 'a3000000-0000-0000-0000-000000000003';
    raise exception 'disposition UPDATE was allowed';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.aios_backlog_dispositions where entity_id = 'a3000000-0000-0000-0000-000000000003';
    raise exception 'disposition DELETE was allowed';
  exception when insufficient_privilege then null; end;

  -- 8. The integrity guard is still enabled and still rejects the invalid transition when attempted directly.
  if not exists (select 1 from pg_trigger where tgrelid = 'public.aios_approvals'::regclass and tgname = 'trg_aios_validate_approval_integrity' and tgenabled = 'O') then
    raise exception 'approval integrity trigger is not enabled';
  end if;
  begin
    update public.aios_approvals set status = 'expired' where id = 'a3000000-0000-0000-0000-000000000004';
    raise exception 'integrity guard did not reject the cross-organization approval';
  exception when check_violation then null; end;

  -- 9. The classifier is owner-only (no client or service role may call it).
  if has_function_privilege('anon', 'private.aios_approval_binding_defect(uuid)', 'execute')
     or has_function_privilege('authenticated', 'private.aios_approval_binding_defect(uuid)', 'execute')
     or has_function_privilege('service_role', 'private.aios_approval_binding_defect(uuid)', 'execute') then
    raise exception 'binding classifier is executable by a client role';
  end if;
end $$;

rollback;
select 'ok: approval convergence regression' as result;
