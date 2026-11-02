-- Allow explicit owner decisions to be recorded in the append-only disposition history.
-- Adds classification 'owner_decision' and dispositions 'owner_decision_retain' / 'owner_decision_cancel'. Existing rows are untouched
-- (the widened checks are supersets, so validation of existing data always passes). The effective-disposition view now ranks an
-- owner decision above automated rows when timestamps tie; otherwise the latest appended row wins, as before.
alter table public.aios_backlog_dispositions drop constraint if exists aios_backlog_dispositions_classification_check;
alter table public.aios_backlog_dispositions add constraint aios_backlog_dispositions_classification_check
  check (classification in ('orphaned_approval','untethered_fixture_approval','historical_test_fixture','legitimate_pending_work','needs_owner_review','owner_decision'));
alter table public.aios_backlog_dispositions drop constraint if exists aios_backlog_dispositions_disposition_check;
alter table public.aios_backlog_dispositions add constraint aios_backlog_dispositions_disposition_check
  check (disposition in ('expire_via_canonical_job','retain_queued_no_action','manual_review','owner_decision_retain','owner_decision_cancel'));

create or replace view public.aios_backlog_effective_dispositions with (security_invoker = true) as
select distinct on (entity_type, entity_id)
       id, organization_id, entity_type, entity_id, classification, disposition, rationale, decided_by, created_at
from public.aios_backlog_dispositions
order by entity_type, entity_id, created_at desc, (classification = 'owner_decision') desc, (disposition = 'manual_review') desc, id;
