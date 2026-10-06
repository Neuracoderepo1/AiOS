-- Cover every FK flagged by the performance advisor. These matter more than usual
-- here because every RLS policy on this schema will filter on organization_id
-- (and often agent_id/task_id) — without these, RLS-gated queries seq-scan.

create index if not exists idx_aios_agents_department_id on public.aios_agents (department_id);

create index if not exists idx_aios_approvals_organization_id on public.aios_approvals (organization_id);
create index if not exists idx_aios_approvals_agent_id on public.aios_approvals (agent_id);
create index if not exists idx_aios_approvals_task_id on public.aios_approvals (task_id);

create index if not exists idx_aios_audit_events_agent_id on public.aios_audit_events (agent_id);
create index if not exists idx_aios_audit_events_task_id on public.aios_audit_events (task_id);

create index if not exists idx_aios_departments_organization_id on public.aios_departments (organization_id);

create index if not exists idx_aios_memory_organization_id on public.aios_memory (organization_id);
create index if not exists idx_aios_memory_agent_id on public.aios_memory (agent_id);

create index if not exists idx_aios_model_runs_organization_id on public.aios_model_runs (organization_id);
create index if not exists idx_aios_model_runs_task_id on public.aios_model_runs (task_id);

create index if not exists idx_aios_projects_organization_id on public.aios_projects (organization_id);

create index if not exists idx_aios_tasks_organization_id on public.aios_tasks (organization_id);
create index if not exists idx_aios_tasks_project_id on public.aios_tasks (project_id);
create index if not exists idx_aios_tasks_parent_task_id on public.aios_tasks (parent_task_id);

create index if not exists idx_aios_tool_invocations_organization_id on public.aios_tool_invocations (organization_id);
create index if not exists idx_aios_tool_invocations_agent_id on public.aios_tool_invocations (agent_id);
create index if not exists idx_aios_tool_invocations_approval_id on public.aios_tool_invocations (approval_id);
