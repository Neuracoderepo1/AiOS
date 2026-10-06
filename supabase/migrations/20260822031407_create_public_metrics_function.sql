-- Public-facing aggregate stats only — no row-level tenant data, no PII.
-- Safe to expose to anon: a visitor learns "12 agents, avg trust 71.2" but
-- cannot see which org they belong to, what they do, or any task/approval
-- content. This does not weaken the RLS model already proven — every
-- underlying table stays locked to authenticated org members.

create or replace function public.aios_public_metrics()
returns json
language sql
security definer
set search_path = public
stable
as $$
  select json_build_object(
    'organizations', (select count(*) from aios_organizations),
    'agents', (select count(*) from aios_agents),
    'avg_trust_score', (select round(coalesce(avg(trust_score), 0), 1) from aios_agents),
    'tasks_total', (select count(*) from aios_tasks),
    'tool_invocations_total', (select count(*) from aios_tool_invocations),
    'tool_invocations_requires_approval', (select count(*) from aios_tool_invocations where status = 'requires_approval'),
    'approvals_pending', (select count(*) from aios_approvals where status = 'pending')
  );
$$;

grant execute on function public.aios_public_metrics() to anon, authenticated;
