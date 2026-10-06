
create table if not exists public.aios_contracts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.aios_organizations(id) on delete cascade,
  agent_id uuid not null references public.aios_agents(id) on delete cascade,
  version int not null,
  risk_level text not null default 'low',
  allowed_tools jsonb not null default '[]'::jsonb,
  limits jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (agent_id, version)
);

-- Only one active contract per agent at a time.
create unique index if not exists idx_aios_contracts_one_active
  on public.aios_contracts(agent_id) where (is_active);

create index if not exists idx_aios_contracts_agent on public.aios_contracts(agent_id, version desc);

alter table public.aios_contracts enable row level security;
create policy aios_contracts_member on public.aios_contracts for all to authenticated
using (public.aios_is_org_member(organization_id)) with check (public.aios_is_org_member(organization_id));

-- Seed v1 contracts for every existing agent from their current authority column,
-- so nothing regresses and every agent now has a real versioned history.
insert into public.aios_contracts (organization_id, agent_id, version, risk_level, allowed_tools, limits, is_active)
select a.organization_id, a.id, 1,
  coalesce(a.authority->>'risk_level','low'),
  coalesce(a.authority->'allowed_tools','[]'::jsonb),
  coalesce(a.authority->'limits','{}'::jsonb),
  true
from public.aios_agents a
where not exists (select 1 from public.aios_contracts c where c.agent_id = a.id);
