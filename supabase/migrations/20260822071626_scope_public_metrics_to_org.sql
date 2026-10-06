-- aios_public_metrics() previously returned platform-wide aggregates with no
-- tenant boundary, readable by any authenticated user regardless of org
-- membership. Redefining to take an org_id param, scoped by aios_is_org_member(),
-- matching the access-control pattern already used by aios_is_org_admin /
-- aios_is_org_member. Old zero-arg signature is dropped so callers can't
-- silently keep hitting the unscoped version.

drop function if exists public.aios_public_metrics();

create function public.aios_public_metrics(org_id uuid)
returns json
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when not public.aios_is_org_member(org_id) then
      json_build_object('error', 'not a member of this organization')
    else
      json_build_object(
        'organization_id', org_id,
        'agents', (select count(*) from aios_agents where organization_id = org_id),
        'avg_trust_score', (select round(coalesce(avg(trust_score), 0), 1) from aios_agents where organization_id = org_id),
        'tasks_total', (select count(*) from aios_tasks where organization_id = org_id),
        'tool_invocations_total', (select count(*) from aios_tool_invocations where organization_id = org_id),
        'tool_invocations_requires_approval', (select count(*) from aios_tool_invocations where organization_id = org_id and status = 'requires_approval'),
        'approvals_pending', (select count(*) from aios_approvals where organization_id = org_id and status = 'pending')
      )
  end;
$$;

revoke execute on function public.aios_public_metrics(uuid) from public;
grant execute on function public.aios_public_metrics(uuid) to authenticated;
grant execute on function public.aios_public_metrics(uuid) to service_role;
