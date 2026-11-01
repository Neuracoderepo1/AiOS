-- Regression: one malformed approval must not abort convergence of the rest of the batch.
--
-- Fixtures are created in a transaction that is rolled back. Legacy-shaped rows (e.g. an approval whose agent belongs to
-- another organization) cannot be produced through the guarded writers by design, so USER triggers are disabled ONLY while
-- fixtures are inserted and re-enabled before the job runs. The job itself always runs with every trigger enabled, exactly
-- as in production. This file never touches a trigger in production; it runs against a throwaway local database.
begin;

do $$
declare
  t text;
  orgA uuid := gen_random_uuid(); orgB uuid := gen_random_uuid();
  agA uuid := gen_random_uuid();  agB uuid := gen_random_uuid();
  tk uuid := gen_random_uuid();   ms uuid := gen_random_uuid();
  ap_bad uuid := gen_random_uuid();     -- agent belongs to org B, approval to org A; OLDEST so it would be hit first
  ap_xt uuid := gen_random_uuid();      -- linked (via approval_id) to an invocation of ANOTHER tenant
  ap_leg uuid := gen_random_uuid();     -- valid legacy: NULL expires_at, linked only via invocation.approval_id
  ap_task uuid := gen_random_uuid();    -- valid legacy with task + mission chain
  ap_orph uuid := gen_random_uuid();    -- valid legacy, no invocation
  ap_exp uuid := gen_random_uuid();     -- explicit lapsed expires_at
  ap_fly uuid := gen_random_uuid();     -- invocation is running: must NOT be expired
  ap_new uuid := gen_random_uuid();     -- fresh, NULL expires_at: not lapsed yet
  i_xt uuid := gen_random_uuid(); i_leg uuid := gen_random_uuid(); i_task uuid := gen_random_uuid(); i_fly uuid := gen_random_uuid();
  r jsonb; r2 jsonb; n int; s text; s2 text;
begin
  -- precondition: no user trigger is disabled in the schema under test
  if exists (select 1 from pg_trigger g join pg_class c on c.oid=g.tgrelid join pg_namespace n on n.oid=c.relnamespace
              where n.nspname='public' and c.relname like 'aios\_%' and not g.tgisinternal and g.tgenabled <> 'O') then
    raise exception 'precondition: a public aios_* trigger is not enabled';
  end if;

  foreach t in array array['aios_organizations','aios_agents','aios_tasks','aios_missions','aios_tool_invocations','aios_approvals'] loop
    execute format('alter table public.%I disable trigger user', t);
  end loop;

  insert into public.aios_organizations (id, name) values (orgA, 'conv-test-A'), (orgB, 'conv-test-B');
  insert into public.aios_agents (id, organization_id, agent_key, name, role, authority)
    values (agA, orgA, 'conv-a', 'conv a', 'tester', '{"risk_level":"low","allowed_tools":[],"limits":{}}'),
           (agB, orgB, 'conv-b', 'conv b', 'tester', '{"risk_level":"low","allowed_tools":[],"limits":{}}');
  insert into public.aios_missions (id, organization_id, title, objective, status) values (ms, orgA, 'conv m', 'conv', 'blocked_pending_approval');
  insert into public.aios_tasks (id, organization_id, mission_id, title, status) values (tk, orgA, ms, 'conv t', 'blocked_pending_approval');

  insert into public.aios_approvals (id, organization_id, agent_id, action, risk_level, status, created_at) values
    (ap_bad,  orgA, agB, 'conv', 'low', 'pending', now() - interval '72 hours'),
    (ap_xt,   orgA, agA, 'conv', 'low', 'pending', now() - interval '60 hours'),
    (ap_leg,  orgA, agA, 'conv', 'low', 'pending', now() - interval '50 hours'),
    (ap_task, orgA, agA, 'conv', 'low', 'pending', now() - interval '49 hours'),
    (ap_orph, orgA, agA, 'conv', 'low', 'pending', now() - interval '48 hours'),
    (ap_fly,  orgA, agA, 'conv', 'low', 'pending', now() - interval '47 hours'),
    (ap_new,  orgA, agA, 'conv', 'low', 'pending', now());
  insert into public.aios_approvals (id, organization_id, agent_id, action, risk_level, status, expires_at, created_at)
    values (ap_exp, orgA, agA, 'conv', 'low', 'pending', now() - interval '1 hour', now() - interval '3 hours');

  insert into public.aios_tool_invocations (id, organization_id, agent_id, task_id, tool_name, status, approval_id) values
    (i_xt,   orgB, agB, null, 'conv', 'requires_approval', ap_xt),
    (i_leg,  orgA, agA, null, 'conv', 'requires_approval', ap_leg),
    (i_task, orgA, agA, tk,   'conv', 'requires_approval', ap_task),
    (i_fly,  orgA, agA, null, 'conv', 'running',           ap_fly);

  foreach t in array array['aios_organizations','aios_agents','aios_tasks','aios_missions','aios_tool_invocations','aios_approvals'] loop
    execute format('alter table public.%I enable trigger user', t);
  end loop;

  -- 0. the pre-check classifies the fixtures
  if private.aios_approval_binding_defect(ap_bad) is distinct from 'agent_organization_mismatch' then raise exception 'defect(ap_bad)=%', private.aios_approval_binding_defect(ap_bad); end if;
  if private.aios_approval_binding_defect(ap_xt)  is distinct from 'linked_invocation_organization_mismatch' then raise exception 'defect(ap_xt)=%', private.aios_approval_binding_defect(ap_xt); end if;
  if private.aios_approval_binding_defect(ap_leg) is not null or private.aios_approval_binding_defect(ap_task) is not null
     or private.aios_approval_binding_defect(ap_orph) is not null then raise exception 'valid fixtures flagged as defective'; end if;

  -- 1. the job runs to completion with a malformed record at the head of the batch (previously: whole batch aborted)
  r := private.aios_expire_stale_approvals();

  -- 2. report
  if (r->>'invalid_bindings_skipped')::int <> 2 then raise exception 'expected 2 invalid skipped, report=%', r; end if;
  if (r->>'transition_errors_skipped')::int <> 0 then raise exception 'unexpected transition errors, report=%', r; end if;
  if (r->>'approvals_expired')::int < 2 or (r->>'orphan_approvals_expired')::int < 2 or (r->>'tasks_expired')::int < 1
     or (r->>'skipped_in_flight')::int < 1 then raise exception 'report counts too low: %', r; end if;
  if not (r->'skipped_records') @> jsonb_build_array(jsonb_build_object('approval_id', ap_bad, 'defect', 'agent_organization_mismatch')) then
    raise exception 'skipped_records does not list the malformed approval: %', r; end if;

  -- 3. eligible legacy approvals transitioned, with linked invocations / task / mission
  for s in select status from public.aios_approvals where id in (ap_leg, ap_task, ap_orph, ap_exp) loop
    if s <> 'expired' then raise exception 'eligible approval not expired (%)', s; end if;
  end loop;
  if (select status from public.aios_tool_invocations where id = i_leg) <> 'expired'
     or (select error_code from public.aios_tool_invocations where id = i_leg) <> 'APPROVAL_EXPIRED' then raise exception 'legacy invocation not expired'; end if;
  if (select status from public.aios_tool_invocations where id = i_task) <> 'expired' then raise exception 'task invocation not expired'; end if;
  if (select status from public.aios_tasks where id = tk) <> 'expired' then raise exception 'task not expired'; end if;
  if (select status from public.aios_missions where id = ms) <> 'failed' then raise exception 'mission not failed'; end if;

  -- 4. protected records untouched: malformed, cross-tenant, in-flight, fresh
  for s, s2 in select a.status, coalesce(a.approval_reason,'') || coalesce(a.reviewed_at::text,'') from public.aios_approvals a where a.id in (ap_bad, ap_xt, ap_fly, ap_new) loop
    if s <> 'pending' or s2 <> '' then raise exception 'protected approval was modified (% / %)', s, s2; end if;
  end loop;
  if (select status from public.aios_tool_invocations where id = i_xt) <> 'requires_approval' then raise exception 'cross-tenant invocation was modified'; end if;
  if (select status from public.aios_tool_invocations where id = i_fly) <> 'running' then raise exception 'in-flight invocation was modified'; end if;

  -- 5. manual-review dispositions appended (once each), by the job
  select count(*) into n from public.aios_backlog_dispositions
   where entity_type='approval' and entity_id in (ap_bad, ap_xt) and classification='needs_owner_review'
     and disposition='manual_review' and decided_by='job:aios_expire_stale_approvals';
  if n <> 2 then raise exception 'expected 2 manual_review dispositions, got %', n; end if;

  -- 6. idempotent: second run changes nothing and appends nothing
  r2 := private.aios_expire_stale_approvals();
  if (r2->>'approvals_expired')::int <> 0 or (r2->>'orphan_approvals_expired')::int <> 0 or (r2->>'tasks_expired')::int <> 0
     or (r2->>'invalid_bindings_skipped')::int <> 2 then raise exception 'second run not idempotent: %', r2; end if;
  select count(*) into n from public.aios_backlog_dispositions where entity_type='approval' and entity_id in (ap_bad, ap_xt);
  if n <> 2 then raise exception 'duplicate dispositions after second run: %', n; end if;

  -- 7. append-only history preserved
  begin
    update public.aios_backlog_dispositions set rationale = 'tamper' where entity_id = ap_bad;
    raise exception 'disposition update was allowed';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.aios_backlog_dispositions where entity_id = ap_bad;
    raise exception 'disposition delete was allowed';
  exception when insufficient_privilege then null; end;

  -- 8. the integrity guards were never disabled
  if exists (select 1 from pg_trigger where tgrelid='public.aios_approvals'::regclass
              and tgname in ('trg_aios_validate_approval_integrity','trg_validate_agent_org','trg_validate_task_org','trg_aios_approval_status_guard')
              and tgenabled <> 'O') then raise exception 'an approval integrity trigger is not enabled'; end if;
  if (select count(*) from pg_trigger where tgrelid='public.aios_approvals'::regclass and tgname='trg_aios_validate_approval_integrity') <> 1 then
    raise exception 'approval integrity trigger missing'; end if;
end $$;

rollback;
select 'ok: approval convergence regression' as result;
