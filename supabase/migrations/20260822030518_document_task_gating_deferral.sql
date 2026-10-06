comment on table public.aios_tasks is
'Task assignment is deliberately NOT gated against agent authority (as of 2026-08-22).
Enforcement lives at the tool_invocation layer (see aios_tool_invocations_authority_check
trigger + aios_enforce_agent_authority()), which is closer to actual consequence.
Reasoning: a task assigned to an "unsuitable" agent causes no harm until that agent
tries to invoke a tool, which is already checked. Revisit this if aios_missions/
aios_tasks ever gains an autonomous auto-assign flow with no human/orchestrator
judgment upstream of the assignment — that is the condition under which task-level
gating would earn its cost.';

comment on column public.aios_agents.authority is
'Shared contract across all agents: {"risk_level": "low|medium|high",
"allowed_tools": [...], "limits": {}}. risk_level and allowed_tools are checked
by aios_enforce_agent_authority() on every tool_invocation. limits is a free-form,
domain-specific bag (e.g. max_position_usd for trading agents) and is NOT enforced
generically — only by domain-specific logic that knows to look for those keys.
Enforced structurally by aios_agents_authority_shape CHECK constraint.';
