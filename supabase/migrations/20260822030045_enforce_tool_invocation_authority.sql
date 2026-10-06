-- Enforces the promise AiOS is meant to make: an agent cannot execute a tool
-- call outside its declared authority. This is the backstop, not the primary
-- gate — application code should already be checking authority before writing
-- a tool_invocation. This trigger catches drift, bugs, or a second calling
-- surface that bypasses app logic.
--
-- Behavior: if the invocation's tool isn't in the agent's allowed_tools, or
-- its risk_level exceeds the agent's ceiling, the invocation is not rejected
-- outright — it's forced into 'requires_approval' status so it routes through
-- the aios_approvals gate instead of executing directly. This matches the
-- existing design (tool_invocations.approval_id / risk_level / status).

create or replace function public.aios_enforce_agent_authority()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  agent_authority jsonb;
  agent_risk_rank int;
  invocation_risk_rank int;
  risk_order jsonb := '{"low": 1, "medium": 2, "high": 3}'::jsonb;
begin
  if new.agent_id is null then
    return new; -- no agent assigned yet, nothing to check
  end if;

  select authority into agent_authority
  from public.aios_agents
  where id = new.agent_id;

  if agent_authority is null then
    return new; -- agent not found; FK constraint already guards this
  end if;

  agent_risk_rank := (risk_order -> (agent_authority->>'risk_level'))::int;
  invocation_risk_rank := (risk_order -> new.risk_level)::int;

  if not (agent_authority->'allowed_tools' ? new.tool_name)
     or invocation_risk_rank > agent_risk_rank then
    new.status := 'requires_approval';
  end if;

  return new;
end;
$$;

create trigger aios_tool_invocations_authority_check
before insert or update of tool_name, risk_level, agent_id
on public.aios_tool_invocations
for each row
execute function public.aios_enforce_agent_authority();
