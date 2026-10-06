-- Harden legacy privileged entry points and repair the service-role evaluation path.
-- Keep SECURITY DEFINER only where it is required by triggers or deliberate RLS-bypass RPCs.

REVOKE ALL ON FUNCTION public.aios_kernel_evaluate(uuid,uuid,text,text,numeric,integer,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.aios_kernel_evaluate(uuid,uuid,text,text,numeric,integer,jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.aios_kernel_evaluate(
  p_agent_id uuid,
  p_task_id uuid,
  p_tool_name text,
  p_risk_level text DEFAULT 'low',
  p_usd_amount numeric DEFAULT NULL,
  p_concurrent_count integer DEFAULT NULL,
  p_arguments jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO ''
AS $$
DECLARE
  v_org_id uuid;
  v_row public.aios_tool_invocations;
  v_merged_args jsonb;
BEGIN
  IF coalesce(auth.jwt()->>'role','') <> 'service_role' THEN
    RAISE EXCEPTION 'service-role execution context required' USING errcode='42501';
  END IF;

  SELECT organization_id INTO v_org_id
  FROM public.aios_agents
  WHERE id = p_agent_id;

  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'unknown agent_id %', p_agent_id;
  END IF;

  v_merged_args := coalesce(p_arguments,'{}'::jsonb)
    || CASE WHEN p_usd_amount IS NOT NULL THEN jsonb_build_object('usd_amount',p_usd_amount) ELSE '{}'::jsonb END
    || CASE WHEN p_concurrent_count IS NOT NULL THEN jsonb_build_object('concurrent_count',p_concurrent_count) ELSE '{}'::jsonb END;

  INSERT INTO public.aios_tool_invocations
    (organization_id,agent_id,task_id,tool_name,tool_key,arguments,status,risk_level,requested_by,idempotency_key,request_id)
  VALUES
    (v_org_id,p_agent_id,p_task_id,p_tool_name,p_tool_name,v_merged_args,'requested',p_risk_level,NULL,
     'legacy-kernel-evaluate:'||gen_random_uuid()::text,gen_random_uuid())
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'decision', CASE v_row.status
      WHEN 'denied' THEN 'deny'
      WHEN 'requires_approval' THEN 'approval'
      WHEN 'approved' THEN 'allow'
      ELSE 'pending'
    END,
    'reason', coalesce(v_row.result->>'kernel_reason','within contract'),
    'tool_invocation_id', v_row.id,
    'approval_id', v_row.approval_id,
    'status', v_row.status
  );
END;
$$;

-- The old public trigger implementation is not attached to any live trigger.
-- Remove its executable surface rather than leaving an obsolete privileged endpoint.
REVOKE ALL ON FUNCTION public.aios_enforce_agent_authority() FROM PUBLIC, anon, authenticated, service_role;

-- Make the new-user trigger's privileged function safer against search_path attacks.
CREATE OR REPLACE FUNCTION public.aios_handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_org_id uuid;
BEGIN
  INSERT INTO public.aios_organizations (name)
  VALUES (coalesce(new.email, 'New user') || '''s Sandbox')
  RETURNING id INTO v_org_id;

  INSERT INTO public.aios_organization_members (organization_id, user_id, role)
  VALUES (v_org_id, new.id, 'owner');

  INSERT INTO public.aios_agents
    (organization_id, agent_key, name, role, status, trust_score, authority)
  VALUES (
    v_org_id,
    'sandbox-analyst-' || substr(new.id::text, 1, 8),
    'Sandbox Analyst',
    'Research Analyst',
    'idle',
    80.0,
    jsonb_build_object('risk_level','low','allowed_tools',jsonb_build_array('Python','Web','Documents'),'limits','{}'::jsonb)
  );

  RETURN new;
END;
$$;

-- The service-role execution path must be able to record evaluations even though
-- ordinary authenticated callers still require organization membership.
CREATE OR REPLACE FUNCTION private.aios_record_evaluation(
  p_task_id uuid,
  p_invocation_id uuid,
  p_correctness numeric,
  p_completeness numeric,
  p_policy numeric,
  p_efficiency numeric,
  p_execution numeric,
  p_summary text DEFAULT NULL
)
RETURNS public.aios_evaluations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v public.aios_tasks;
  e public.aios_evaluations;
  s numeric;
  t numeric;
  v_service_role boolean := coalesce(auth.jwt()->>'role','')='service_role';
BEGIN
  SELECT * INTO v FROM public.aios_tasks WHERE id=p_task_id;
  IF v.id IS NULL THEN RAISE EXCEPTION 'task not found'; END IF;
  IF NOT v_service_role AND NOT private.aios_is_org_member(v.organization_id) THEN
    RAISE EXCEPTION 'not authorized' USING errcode='42501';
  END IF;

  IF p_invocation_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.aios_tool_invocations i
    WHERE i.id=p_invocation_id
      AND i.task_id=v.id
      AND i.organization_id=v.organization_id
      AND i.status='succeeded'
  ) THEN
    RAISE EXCEPTION 'evaluation requires a succeeded invocation for the task' USING errcode='42501';
  END IF;

  s=round((p_correctness+p_completeness+p_policy+p_efficiency+p_execution)/5,4);
  INSERT INTO public.aios_evaluations
    (organization_id,agent_id,mission_id,task_id,invocation_id,overall_score,correctness,completeness,policy_compliance,tool_efficiency,execution_success,summary)
  VALUES
    (v.organization_id,v.assigned_agent_id,v.mission_id,v.id,p_invocation_id,s,p_correctness,p_completeness,p_policy,p_efficiency,p_execution,p_summary)
  RETURNING * INTO e;

  SELECT greatest(0,least(100,coalesce(a.trust_score,0)*0.7+s*100*0.3))
    INTO t FROM public.aios_agents a WHERE a.id=v.assigned_agent_id;
  UPDATE public.aios_agents SET trust_score=round(t,2) WHERE id=v.assigned_agent_id;
  RETURN e;
END;
$$;

REVOKE ALL ON FUNCTION private.aios_record_evaluation(uuid,uuid,numeric,numeric,numeric,numeric,numeric,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.aios_record_evaluation(uuid,uuid,numeric,numeric,numeric,numeric,numeric,text) TO service_role;
