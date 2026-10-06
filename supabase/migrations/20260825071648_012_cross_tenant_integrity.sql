
-- Development 3: guarantee organization_id always matches the referenced
-- agent/task's own organization_id, in the database, regardless of caller.
-- Confirmed exploitable before this migration: an authenticated member of
-- one org could insert a tool_invocation claiming their own organization_id
-- while pointing agent_id at a different org's agent — RLS only checked
-- that the caller belonged to the claimed organization_id, never that the
-- referenced agent actually belonged to it too.

create or replace function public.aios_validate_agent_org()
returns trigger language plpgsql as $$
declare v_agent_org uuid;
begin
  if new.agent_id is null then return new; end if;
  select organization_id into v_agent_org from public.aios_agents where id = new.agent_id;
  if v_agent_org is null then
    raise exception 'agent_id % does not exist', new.agent_id;
  end if;
  if v_agent_org is distinct from new.organization_id then
    raise exception 'organization_id (%) does not match agent''s organization (%)', new.organization_id, v_agent_org;
  end if;
  return new;
end; $$;

create or replace function public.aios_validate_task_org()
returns trigger language plpgsql as $$
declare v_task_org uuid;
begin
  if new.task_id is null then return new; end if;
  select organization_id into v_task_org from public.aios_tasks where id = new.task_id;
  if v_task_org is null then
    raise exception 'task_id % does not exist', new.task_id;
  end if;
  if v_task_org is distinct from new.organization_id then
    raise exception 'organization_id (%) does not match task''s organization (%)', new.organization_id, v_task_org;
  end if;
  return new;
end; $$;

create or replace function public.aios_validate_mission_org()
returns trigger language plpgsql as $$
declare v_mission_org uuid;
begin
  if new.mission_id is null then return new; end if;
  select organization_id into v_mission_org from public.aios_missions where id = new.mission_id;
  if v_mission_org is null then
    raise exception 'mission_id % does not exist', new.mission_id;
  end if;
  if v_mission_org is distinct from new.organization_id then
    raise exception 'organization_id (%) does not match mission''s organization (%)', new.organization_id, v_mission_org;
  end if;
  return new;
end; $$;

-- Tables with an agent_id + organization_id pair:
drop trigger if exists trg_validate_agent_org on public.aios_tool_invocations;
create trigger trg_validate_agent_org before insert or update of agent_id, organization_id
  on public.aios_tool_invocations for each row execute function public.aios_validate_agent_org();

drop trigger if exists trg_validate_agent_org on public.aios_contracts;
create trigger trg_validate_agent_org before insert or update of agent_id, organization_id
  on public.aios_contracts for each row execute function public.aios_validate_agent_org();

drop trigger if exists trg_validate_agent_org on public.aios_approvals;
create trigger trg_validate_agent_org before insert or update of agent_id, organization_id
  on public.aios_approvals for each row execute function public.aios_validate_agent_org();

drop trigger if exists trg_validate_agent_org on public.aios_audit_events;
create trigger trg_validate_agent_org before insert or update of agent_id, organization_id
  on public.aios_audit_events for each row execute function public.aios_validate_agent_org();

drop trigger if exists trg_validate_agent_org on public.aios_memory;
create trigger trg_validate_agent_org before insert or update of agent_id, organization_id
  on public.aios_memory for each row execute function public.aios_validate_agent_org();

drop trigger if exists trg_validate_agent_org on public.aios_model_runs;
create trigger trg_validate_agent_org before insert or update of agent_id, organization_id
  on public.aios_model_runs for each row execute function public.aios_validate_agent_org();

drop trigger if exists trg_validate_agent_org on public.aios_tasks;
create trigger trg_validate_agent_org before insert or update of assigned_agent_id, organization_id
  on public.aios_tasks for each row execute function public.aios_validate_agent_org();

-- Tables with a task_id + organization_id pair (task_id references aios_tasks,
-- reuse the agent-org validator's shape but against tasks):
drop trigger if exists trg_validate_task_org on public.aios_tool_invocations;
create trigger trg_validate_task_org before insert or update of task_id, organization_id
  on public.aios_tool_invocations for each row execute function public.aios_validate_task_org();

drop trigger if exists trg_validate_task_org on public.aios_approvals;
create trigger trg_validate_task_org before insert or update of task_id, organization_id
  on public.aios_approvals for each row execute function public.aios_validate_task_org();

drop trigger if exists trg_validate_task_org on public.aios_audit_events;
create trigger trg_validate_task_org before insert or update of task_id, organization_id
  on public.aios_audit_events for each row execute function public.aios_validate_task_org();

-- Tables with a mission_id + organization_id pair:
drop trigger if exists trg_validate_mission_org on public.aios_tasks;
create trigger trg_validate_mission_org before insert or update of mission_id, organization_id
  on public.aios_tasks for each row execute function public.aios_validate_mission_org();
