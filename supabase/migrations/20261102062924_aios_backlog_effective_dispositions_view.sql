create or replace view public.aios_backlog_effective_dispositions with (security_invoker = true) as
select distinct on (entity_type, entity_id)
       id, organization_id, entity_type, entity_id, classification, disposition, rationale, decided_by, created_at
from public.aios_backlog_dispositions
order by entity_type, entity_id, created_at desc, (disposition = 'manual_review') desc, id;

revoke all on public.aios_backlog_effective_dispositions from public, anon, authenticated;
grant select on public.aios_backlog_effective_dispositions to authenticated, service_role;
