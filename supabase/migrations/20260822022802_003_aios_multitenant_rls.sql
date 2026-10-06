create table if not exists public.aios_organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.aios_organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','admin','manager','member','viewer')),
  created_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create index if not exists idx_aios_org_members_user on public.aios_organization_members(user_id);
create index if not exists idx_aios_org_members_org on public.aios_organization_members(organization_id);

create or replace function public.aios_is_org_member(org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.aios_organization_members m
    where m.organization_id = org_id
      and m.user_id = (select auth.uid())
  );
$$;

create or replace function public.aios_is_org_admin(org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.aios_organization_members m
    where m.organization_id = org_id
      and m.user_id = (select auth.uid())
      and m.role in ('owner','admin')
  );
$$;

alter table public.aios_organization_members enable row level security;
alter table public.aios_organizations enable row level security;
alter table public.aios_departments enable row level security;
alter table public.aios_agents enable row level security;
alter table public.aios_projects enable row level security;
alter table public.aios_tasks enable row level security;
alter table public.aios_memory enable row level security;
alter table public.aios_approvals enable row level security;
alter table public.aios_model_runs enable row level security;
alter table public.aios_audit_events enable row level security;
alter table public.aios_missions enable row level security;
alter table public.aios_tool_invocations enable row level security;

create policy aios_members_select on public.aios_organization_members for select to authenticated
using (user_id = (select auth.uid()) or public.aios_is_org_member(organization_id));
create policy aios_members_insert on public.aios_organization_members for insert to authenticated
with check (public.aios_is_org_admin(organization_id));
create policy aios_members_update on public.aios_organization_members for update to authenticated
using (public.aios_is_org_admin(organization_id)) with check (public.aios_is_org_admin(organization_id));
create policy aios_members_delete on public.aios_organization_members for delete to authenticated
using (public.aios_is_org_admin(organization_id));

create policy aios_org_select on public.aios_organizations for select to authenticated
using (public.aios_is_org_member(id));
create policy aios_org_update on public.aios_organizations for update to authenticated
using (public.aios_is_org_admin(id)) with check (public.aios_is_org_admin(id));

create policy aios_departments_member on public.aios_departments for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));
create policy aios_agents_member on public.aios_agents for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));
create policy aios_projects_member on public.aios_projects for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));
create policy aios_tasks_member on public.aios_tasks for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));
create policy aios_memory_member on public.aios_memory for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));
create policy aios_approvals_member on public.aios_approvals for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));
create policy aios_model_runs_member on public.aios_model_runs for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));
create policy aios_audit_member on public.aios_audit_events for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));
create policy aios_missions_member on public.aios_missions for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));
create policy aios_tools_member on public.aios_tool_invocations for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));
