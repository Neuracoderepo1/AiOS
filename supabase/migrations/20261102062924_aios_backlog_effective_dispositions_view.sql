-- Effective disposition per entity. The convergence fix itself is already live as 20261101232313 (captured in this repo); this adds
-- only the read model that resolves append-only history: the latest appended row per entity wins, earlier rows stay untouched.
-- Effective disposition per entity = latest appended row. History stays in the base table. security_invoker keeps RLS in force.
create or replace view public.aios_backlog_effective_dispositions with (security_invoker = true) as
select distinct on (entity_type, entity_id)
       id, organization_id, entity_type, entity_id, classification, disposition, rationale, decided_by, created_at
from public.aios_backlog_dispositions
order by entity_type, entity_id, created_at desc, (disposition = 'manual_review') desc, id;

revoke all on public.aios_backlog_effective_dispositions from public, anon, authenticated;
grant select on public.aios_backlog_effective_dispositions to authenticated, service_role;
revoke insert, update, delete, truncate, references, trigger on public.aios_backlog_effective_dispositions from service_role;
