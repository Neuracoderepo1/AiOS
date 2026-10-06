-- Per WARDEN directive: "The score must be explainable... trust does not
-- equal authority." aios_agents.trust_score is currently a static stored
-- number with no way to see what it's made of. This function computes a
-- transparent breakdown from the agent's real task/invocation/approval
-- history, in the same shape as the directive's own example (positive
-- factors, negative factors, risk modifier). It does not touch or
-- override the stored trust_score column — that's left alone so nothing
-- reading it today breaks; this is additive, callable wherever the UI
-- wants to show the "why" behind the number.
CREATE OR REPLACE FUNCTION public.aios_agent_trust_explain(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_org_id uuid;
  v_completed int;
  v_failed int;
  v_denied int;
  v_total_tasks int;
  v_completion_rate numeric;
  v_rejected_approvals int;
  v_stored_score numeric;
  v_computed_score numeric;
  v_risk_modifier text;
BEGIN
  SELECT organization_id, trust_score INTO v_org_id, v_stored_score
  FROM public.aios_agents WHERE id = p_agent_id;

  IF v_org_id IS NULL THEN
    RETURN jsonb_build_object('error', 'agent not found');
  END IF;

  IF NOT public.aios_is_org_member(v_org_id) THEN
    RETURN jsonb_build_object('error', 'not authorized to view this agent''s trust score');
  END IF;

  SELECT
    count(*) FILTER (WHERE status = 'completed'),
    count(*) FILTER (WHERE status = 'failed'),
    count(*)
  INTO v_completed, v_failed, v_total_tasks
  FROM public.aios_tasks
  WHERE assigned_agent_id = p_agent_id
    AND status IN ('completed', 'failed');

  SELECT count(*) INTO v_denied
  FROM public.aios_tool_invocations
  WHERE agent_id = p_agent_id AND status = 'denied';

  SELECT count(*) INTO v_rejected_approvals
  FROM public.aios_approvals
  WHERE agent_id = p_agent_id AND status = 'rejected';

  v_completion_rate := CASE WHEN v_total_tasks > 0
    THEN round((v_completed::numeric / v_total_tasks) * 100, 1)
    ELSE NULL END;

  -- Simple, transparent scoring: start at 100, subtract for real negative
  -- signals. This is intentionally legible rather than a black box —
  -- every point lost maps to a specific, listed reason below.
  v_computed_score := 100
    - (v_failed * 3)
    - (v_denied * 5)
    - (v_rejected_approvals * 4);
  v_computed_score := greatest(0, least(100, v_computed_score));

  v_risk_modifier := CASE
    WHEN v_denied > 0 OR v_rejected_approvals > 0 THEN 'medium'
    WHEN v_failed > 2 THEN 'medium'
    ELSE 'low'
  END;

  RETURN jsonb_build_object(
    'agent_id', p_agent_id,
    'stored_trust_score', v_stored_score,
    'computed_trust_score', v_computed_score,
    'positive', jsonb_build_array(
      format('%s completed tasks', v_completed),
      CASE WHEN v_completion_rate IS NOT NULL
        THEN format('%s%% task completion rate', v_completion_rate)
        ELSE 'no completed/failed tasks yet to compute a completion rate' END
    ),
    'negative', jsonb_build_array(
      format('%s failed executions', v_failed),
      format('%s denied authorization requests', v_denied),
      format('%s rejected approval requests', v_rejected_approvals)
    ),
    'risk_modifier', v_risk_modifier
  );
END;
$function$;

-- Lock down like every other SECURITY DEFINER function on this schema:
-- callable by authenticated users (who then get org-membership-checked
-- inside the function body), not by anon.
REVOKE EXECUTE ON FUNCTION public.aios_agent_trust_explain(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aios_agent_trust_explain(uuid) TO authenticated;
