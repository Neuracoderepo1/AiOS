update public.aios_demo_support_tickets set organization_id='9fbeb772-ae9b-4bb5-8656-cd127a747932' where organization_id is null
  and exists (select 1 from public.aios_organizations o where o.id='9fbeb772-ae9b-4bb5-8656-cd127a747932'); -- replayability guard: production-only org
