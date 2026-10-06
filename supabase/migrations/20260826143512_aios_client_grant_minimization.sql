do $$ declare t text; begin foreach t in array array['aios_agents','aios_approvals','aios_audit_events','aios_contracts','aios_demo_support_tickets','aios_departments','aios_evaluations','aios_memory','aios_missions','aios_model_runs','aios_organization_members','aios_organizations','aios_projects','aios_tasks','aios_tool_invocations','aios_tools'] loop execute format('revoke all on public.%I from anon',t); execute format('revoke all on public.%I from authenticated',t); end loop; end $$;

grant select on public.aios_agents,public.aios_approvals,public.aios_audit_events,public.aios_contracts,public.aios_demo_support_tickets,public.aios_departments,public.aios_evaluations,public.aios_memory,public.aios_missions,public.aios_model_runs,public.aios_organization_members,public.aios_organizations,public.aios_projects,public.aios_tasks,public.aios_tool_invocations,public.aios_tools to authenticated;
grant insert,update,delete on public.aios_agents to authenticated;
grant insert,update on public.aios_contracts to authenticated;
grant insert,update,delete on public.aios_departments to authenticated;
grant insert,update,delete on public.aios_missions to authenticated;
grant insert,update,delete on public.aios_organization_members to authenticated;
grant update on public.aios_organizations to authenticated;
grant insert,update,delete on public.aios_projects to authenticated;
grant insert,update,delete on public.aios_tasks to authenticated;

-- Explicitly no anonymous Data API access to AiOS control-plane tables.
