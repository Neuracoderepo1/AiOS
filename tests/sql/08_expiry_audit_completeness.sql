-- Regression (additive): expiry job audit completeness, idempotency and mixed valid/invalid batches.
-- Legacy-shaped fixtures are inserted under session_replication_role = replica ONLY inside this rolled-back transaction on a throwaway
-- database (as in 03); the role is reset to origin BEFORE the job runs, so every trigger executes as in production.
begin;
set local session_replication_role = replica;
insert into public.aios_organizations (id, name) values
  ('a8000000-0000-0000-0000-00000000000a', 'exp-org-a'), ('b8000000-0000-0000-0000-00000000000b', 'exp-org-b');
insert into public.aios_agents (id, organization_id, agent_key, name, role, authority) values
  ('b8100000-0000-0000-0000-000000000001', 'b8000000-0000-0000-0000-00000000000b', 'exp-agent-b', 'exp agent b', 'tester', '{"risk_level":"low","allowed_tools":[],"limits":{}}');
insert into public.aios_approvals (id, organization_id, agent_id, action, risk_level, status, created_at) values
  ('a8300000-0000-0000-0000-000000000001','a8000000-0000-0000-0000-00000000000a',null,'exp','low','pending', now() - interval '3 days'),
  ('a8300000-0000-0000-0000-000000000002','a8000000-0000-0000-0000-00000000000a',null,'exp','low','pending', now() - interval '3 days'),
  ('a8300000-0000-0000-0000-000000000003','a8000000-0000-0000-0000-00000000000a',null,'exp','low','pending', now() - interval '3 days'),
  ('a8300000-0000-0000-0000-000000000009','a8000000-0000-0000-0000-00000000000a','b8100000-0000-0000-0000-000000000001','exp','low','pending', now() - interval '10 days'); -- invalid: agent in another org (oldest)
set local session_replication_role = origin;

create temp table _exp_run (n int, r jsonb);
insert into _exp_run select 1, private.aios_expire_stale_approvals();
insert into _exp_run select 2, private.aios_expire_stale_approvals();
insert into _exp_run select 3, private.aios_expire_stale_approvals();

do $$
declare r1 jsonb := (select r from _exp_run where n=1); r2 jsonb := (select r from _exp_run where n=2); r3 jsonb := (select r from _exp_run where n=3);
  valid uuid[] := array['a8300000-0000-0000-0000-000000000001','a8300000-0000-0000-0000-000000000002','a8300000-0000-0000-0000-000000000003']::uuid[];
  bad uuid := 'a8300000-0000-0000-0000-000000000009'; id uuid; n int;
begin
  -- Mixed batch: the oldest record is invalid and must not block the valid ones.
  if (r1->>'orphan_approvals_expired')::int <> 3 then raise exception 'expected 3 valid expirations in a mixed batch: %', r1; end if;
  if (r1->>'invalid_bindings_skipped')::int <> 1 or (r1->>'transition_errors_skipped')::int <> 0 then raise exception 'unexpected skip counts: %', r1; end if;
  if exists (select 1 from public.aios_approvals where id = any(valid) and status <> 'expired') then raise exception 'a valid approval was not expired'; end if;

  -- Audit exactly once per transition (pending -> expired), for every approval, across three runs.
  foreach id in array valid loop
    select count(*) into n from public.aios_audit_events where approval_id = id and event_type = 'approval_changed' and new_state = 'expired' and previous_state = 'pending';
    if n <> 1 then raise exception 'approval % has % expiry audit events, expected exactly 1', id, n; end if;
  end loop;

  -- Invalid record: preserved, still pending, unmodified, no expiry audit, exactly one review disposition after 3 runs.
  if not exists (select 1 from public.aios_approvals where id = bad and status = 'pending' and reviewed_at is null) then raise exception 'invalid approval was modified or deleted'; end if;
  if exists (select 1 from public.aios_audit_events where approval_id = bad) then raise exception 'invalid approval produced an audit event'; end if;
  select count(*) into n from public.aios_backlog_dispositions where entity_type='approval' and entity_id = bad and disposition = 'manual_review';
  if n <> 1 then raise exception 'expected exactly 1 manual_review disposition, got %', n; end if;

  -- Idempotent: runs 2 and 3 change nothing and the invalid record is re-reported each time.
  if (r2->>'approvals_expired')::int <> 0 or (r2->>'orphan_approvals_expired')::int <> 0 or (r3->>'orphan_approvals_expired')::int <> 0 then raise exception 'repeat runs were not no-ops: % %', r2, r3; end if;
  if (r2->>'invalid_bindings_skipped')::int <> 1 or (r3->>'invalid_bindings_skipped')::int <> 1 then raise exception 'invalid record not re-reported'; end if;

  -- Integrity guard still rejects the invalid transition when attempted directly.
  begin update public.aios_approvals set status = 'expired' where id = bad; raise exception 'integrity guard did not reject direct transition';
  exception when check_violation then null; end;
end $$;
rollback;
select 'ok: expiry audit completeness' as result;
