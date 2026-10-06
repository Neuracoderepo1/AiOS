-- aios_public_metrics(org_id) is correctly member-gated and belongs to the Founder
-- Console, not the public hero strip. This is a separate, deliberately anonymous
-- function that returns only cross-org aggregate counts — no org names, no agent
-- names, no per-tenant breakdown — safe to expose to unauthenticated visitors.

create or replace function public.aios_platform_metrics()
returns json
language sql
stable security definer
set search_path to 'public'
as $$
  select json_build_object(
    'organizations', (select count(*) from aios_organizations),
    'agents_under_contract', (select count(*) from aios_agents),
    'avg_trust_score', (select round(coalesce(avg(trust_score), 0), 1) from aios_agents),
    'calls_routed_to_approval', (select count(*) from aios_tool_invocations where status = 'requires_approval')
  );
$$;

grant execute on function public.aios_platform_metrics() to anon;
