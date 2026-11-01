-- Linter flagged identical partial-unique indexes on aios_contracts. Keep aios_contracts_one_active_per_agent_idx; drop the twin
-- only if both definitions match and the twin does not back a constraint.
do $$
declare d1 text; d2 text;
begin
  select regexp_replace(indexdef, 'INDEX \S+ ON', 'INDEX x ON') into d1 from pg_indexes where schemaname='public' and indexname='aios_contracts_one_active_per_agent_idx';
  select regexp_replace(indexdef, 'INDEX \S+ ON', 'INDEX x ON') into d2 from pg_indexes where schemaname='public' and indexname='idx_aios_contracts_one_active';
  if d1 is null or d2 is null then
    raise notice 'one of the indexes is missing; nothing to do';
  elsif d1 <> d2 then
    raise notice 'definitions differ; not dropping';
  elsif exists (select 1 from pg_constraint where conindid = 'public.idx_aios_contracts_one_active'::regclass) then
    raise notice 'twin backs a constraint; not dropping';
  else
    drop index public.idx_aios_contracts_one_active;
  end if;
end $$;
