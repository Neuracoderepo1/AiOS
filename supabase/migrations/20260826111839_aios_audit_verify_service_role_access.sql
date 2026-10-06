CREATE OR REPLACE FUNCTION private.verify_audit_chain(p_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  r record;
  v_prev text:='GENESIS:'||p_organization_id::text;
  v_expected text;
  v_count int:=0;
  v_first uuid;
  v_last uuid;
  v_payload text;
  v_service_role boolean := coalesce(auth.jwt()->>'role','')='service_role';
BEGIN
  IF NOT v_service_role AND NOT private.aios_is_org_member(p_organization_id) THEN
    RAISE EXCEPTION 'not authorized' USING errcode='42501';
  END IF;
  FOR r IN SELECT * FROM public.aios_audit_events WHERE organization_id=p_organization_id ORDER BY created_at,id LOOP
    v_count=v_count+1;
    IF v_first IS NULL THEN v_first=r.id; END IF;
    v_last=r.id;
    v_payload=jsonb_build_object('id',r.id,'organization_id',r.organization_id,'actor_user_id',r.actor_user_id,'actor_type',r.actor_type,'agent_id',r.agent_id,'mission_id',r.mission_id,'task_id',r.task_id,'invocation_id',r.invocation_id,'event_type',r.event_type,'previous_state',r.previous_state,'new_state',r.new_state,'tool_name',r.tool_name,'risk_level',r.risk_level,'arguments_hash',r.arguments_hash,'result_hash',r.result_hash,'approval_id',r.approval_id,'created_at',r.created_at,'metadata',r.metadata,'previous_event_hash',v_prev)::text||v_prev;
    v_expected=encode(extensions.digest(v_payload,'sha256'),'hex');
    IF r.previous_event_hash IS DISTINCT FROM v_prev OR r.event_hash IS DISTINCT FROM v_expected THEN
      RETURN jsonb_build_object('valid',false,'events_checked',v_count,'first_event',v_first,'last_event',r.id,'broken_event_id',r.id,'expected_hash',v_expected,'actual_hash',r.event_hash);
    END IF;
    v_prev=r.event_hash;
  END LOOP;
  RETURN jsonb_build_object('valid',true,'events_checked',v_count,'first_event',v_first,'last_event',v_last,'broken_event_id',null,'expected_hash',null,'actual_hash',null);
END;
$$;
REVOKE ALL ON FUNCTION private.verify_audit_chain(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.verify_audit_chain(uuid) TO authenticated,service_role;
