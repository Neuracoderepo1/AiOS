CREATE INDEX IF NOT EXISTS idx_aios_approvals_approved_by ON public.aios_approvals(approved_by) WHERE approved_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_aios_audit_actor_user_id ON public.aios_audit_events(actor_user_id) WHERE actor_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_aios_audit_approval_id ON public.aios_audit_events(approval_id) WHERE approval_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_aios_audit_mission_id ON public.aios_audit_events(mission_id) WHERE mission_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_aios_contracts_org_agent_active ON public.aios_contracts(organization_id,agent_id,is_active,version DESC);
CREATE INDEX IF NOT EXISTS idx_aios_evaluations_invocation_id ON public.aios_evaluations(invocation_id) WHERE invocation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_aios_evaluations_mission_id ON public.aios_evaluations(mission_id) WHERE mission_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_aios_evaluations_task_id ON public.aios_evaluations(task_id) WHERE task_id IS NOT NULL;
DROP INDEX IF EXISTS public.idx_aios_tools_task_created;
