-- Owner decisions are recordable, win in the effective view, and history stays append-only. Rolled back.
begin;
insert into public.aios_organizations (id, name) values ('c0000000-0000-0000-0000-00000000000c', 'owner-decision-test-org');
insert into public.aios_backlog_dispositions (organization_id, entity_type, entity_id, classification, disposition, rationale, decided_by) values
  ('c0000000-0000-0000-0000-00000000000c', 'task', 'c1000000-0000-0000-0000-000000000001', 'needs_owner_review', 'manual_review', 'auto', 'job:test'),
  ('c0000000-0000-0000-0000-00000000000c', 'task', 'c1000000-0000-0000-0000-000000000001', 'owner_decision', 'owner_decision_cancel', 'owner says cancel', 'owner:test'),
  ('c0000000-0000-0000-0000-00000000000c', 'approval', 'c1000000-0000-0000-0000-000000000002', 'owner_decision', 'owner_decision_retain', 'owner says retain', 'owner:test');
do $$
declare d text; n int;
begin
  select disposition into d from public.aios_backlog_effective_dispositions where entity_id = 'c1000000-0000-0000-0000-000000000001';
  if d is distinct from 'owner_decision_cancel' then raise exception 'effective disposition is %, expected owner_decision_cancel', d; end if;
  select count(*) into n from public.aios_backlog_dispositions where entity_id = 'c1000000-0000-0000-0000-000000000001';
  if n <> 2 then raise exception 'history not preserved (% rows)', n; end if;
  begin
    insert into public.aios_backlog_dispositions (organization_id, entity_type, entity_id, classification, disposition, rationale)
    values ('c0000000-0000-0000-0000-00000000000c', 'task', 'c1000000-0000-0000-0000-000000000003', 'owner_decision', 'bogus_value', 'x');
    raise exception 'invalid disposition value was accepted';
  exception when check_violation then null; end;
  begin
    update public.aios_backlog_dispositions set rationale = 'tamper' where entity_id = 'c1000000-0000-0000-0000-000000000002';
    raise exception 'UPDATE allowed';
  exception when insufficient_privilege then null; end;
end $$;
rollback;
select 'ok: owner decision dispositions' as result;
