CREATE OR REPLACE FUNCTION private.aios_resolve_approval(
  p_approval_id uuid,
  p_decision text,
  p_reviewer_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  a public.aios_approvals;
  i public.aios_tool_invocations;
  t public.aios_tasks;
  m public.aios_missions;
  v_now timestamptz := now();
BEGIN
  IF coalesce(auth.jwt()->>'role','') <> 'service_role' THEN
    RAISE EXCEPTION 'service-role execution context required' USING errcode='42501';
  END IF;
  IF p_decision NOT IN ('approved','rejected') THEN
    RAISE EXCEPTION 'invalid approval decision' USING errcode='22023';
  END IF;

  SELECT * INTO a
  FROM public.aios_approvals
  WHERE id=p_approval_id
  FOR UPDATE;
  IF a.id IS NULL THEN RAISE EXCEPTION 'approval not found' USING errcode='P0002'; END IF;
  IF a.status <> 'pending' THEN RAISE EXCEPTION 'approval already resolved: %',a.status USING errcode='40001'; END IF;
  IF a.expires_at IS NOT NULL AND a.expires_at <= v_now THEN
    UPDATE public.aios_approvals SET status='expired',reviewed_at=v_now,reviewed_by=p_reviewer_id,approval_reason=coalesce(p_reason,'approval expired') WHERE id=a.id;
    RAISE EXCEPTION 'approval expired' USING errcode='40001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.aios_organization_members om
    WHERE om.organization_id=a.organization_id
      AND om.user_id=p_reviewer_id
      AND om.role IN ('owner','admin')
  ) THEN
    RAISE EXCEPTION 'reviewer is not an organization owner/admin' USING errcode='42501';
  END IF;

  IF a.invocation_id IS NULL THEN RAISE EXCEPTION 'approval is not linked to an invocation' USING errcode='23514'; END IF;
  SELECT * INTO i FROM public.aios_tool_invocations WHERE id=a.invocation_id FOR UPDATE;
  IF i.id IS NULL THEN RAISE EXCEPTION 'invocation not found' USING errcode='P0002'; END IF;
  IF i.status <> 'requires_approval' THEN RAISE EXCEPTION 'invocation is not awaiting approval: %',i.status USING errcode='40001'; END IF;
  IF a.invocation_id IS DISTINCT FROM i.id OR a.tool_key IS DISTINCT FROM i.tool_key OR a.arguments_hash IS DISTINCT FROM i.arguments_hash THEN
    RAISE EXCEPTION 'approval no longer matches invocation authorization context' USING errcode='42501';
  END IF;

  UPDATE public.aios_approvals
  SET status=p_decision,
      reviewed_by=p_reviewer_id,
      approved_by=CASE WHEN p_decision='approved' THEN p_reviewer_id ELSE NULL END,
      approved_at=CASE WHEN p_decision='approved' THEN v_now ELSE NULL END,
      reviewed_at=v_now,
      approval_reason=p_reason
  WHERE id=a.id;

  IF p_decision='approved' THEN
    UPDATE public.aios_tool_invocations
    SET status='approved'
    WHERE id=i.id AND status='requires_approval';

    IF i.task_id IS NOT NULL THEN
      UPDATE public.aios_tasks
      SET status='approved'
      WHERE id=i.task_id AND status='blocked_pending_approval'
      RETURNING * INTO t;
      IF t.id IS NOT NULL THEN
        UPDATE public.aios_missions
        SET status='running'
        WHERE id=t.mission_id AND status='blocked_pending_approval'
        RETURNING * INTO m;
      END IF;
    END IF;
  ELSE
    UPDATE public.aios_tool_invocations
    SET status='denied',completed_at=v_now,error_code='HUMAN_REJECTED',error_message=p_reason
    WHERE id=i.id AND status='requires_approval';

    IF i.task_id IS NOT NULL THEN
      UPDATE public.aios_tasks
      SET status='failed',result=jsonb_build_object('rejected',true,'reason',p_reason),completed_at=v_now
      WHERE id=i.task_id AND status='blocked_pending_approval'
      RETURNING * INTO t;
      IF t.id IS NOT NULL THEN
        UPDATE public.aios_missions
        SET status='failed',completed_at=v_now
        WHERE id=t.mission_id AND status='blocked_pending_approval'
        RETURNING * INTO m;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'approval_id',a.id,
    'invocation_id',i.id,
    'decision',p_decision,
    'invocation_status',(SELECT status FROM public.aios_tool_invocations WHERE id=i.id),
    'task_id',i.task_id,
    'task_status',(SELECT status FROM public.aios_tasks WHERE id=i.task_id),
    'mission_id',(SELECT mission_id FROM public.aios_tasks WHERE id=i.task_id),
    'mission_status',(SELECT m2.status FROM public.aios_missions m2 JOIN public.aios_tasks t2 ON t2.mission_id=m2.id WHERE t2.id=i.task_id)
  );
END;
$$;

REVOKE ALL ON FUNCTION private.aios_resolve_approval(uuid,text,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.aios_resolve_approval(uuid,text,uuid,text) TO service_role;

CREATE OR REPLACE FUNCTION public.aios_resolve_approval(
  p_approval_id uuid,
  p_decision text,
  p_reviewer_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT private.aios_resolve_approval($1,$2,$3,$4);
$$;

REVOKE ALL ON FUNCTION public.aios_resolve_approval(uuid,text,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.aios_resolve_approval(uuid,text,uuid,text) TO service_role;
