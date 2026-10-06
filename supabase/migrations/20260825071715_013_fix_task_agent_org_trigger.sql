
-- Fixes a bug from the previous migration: aios_tasks uses assigned_agent_id,
-- not agent_id, so the generic validator broke on any update touching
-- organization_id/assigned_agent_id — including every task launch-mission
-- creates. Confirmed broken and fixed in the same sitting, before any real
-- traffic could hit it.

drop trigger if exists trg_validate_agent_org on public.aios_tasks;

create or replace function public.aios_validate_task_agent_org()
returns trigger language plpgsql as $$
declare v_agent_org uuid;
begin
  if new.assigned_agent_id is null then return new; end if;
  select organization_id into v_agent_org from public.aios_agents where id = new.assigned_agent_id;
  if v_agent_org is null then
    raise exception 'assigned_agent_id % does not exist', new.assigned_agent_id;
  end if;
  if v_agent_org is distinct from new.organization_id then
    raise exception 'organization_id (%) does not match assigned agent''s organization (%)', new.organization_id, v_agent_org;
  end if;
  return new;
end; $$;

create trigger trg_validate_task_agent_org before insert or update of assigned_agent_id, organization_id
  on public.aios_tasks for each row execute function public.aios_validate_task_agent_org();
