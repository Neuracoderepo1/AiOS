-- Harden public.aios_kernel_authorize_invocation to match the service-role guard
-- already used by aios_kernel_evaluate and aios_record_evaluation.
CREATE OR REPLACE FUNCTION public.aios_kernel_authorize_invocation(p_invocation_id uuid)
RETURNS aios_tool_invocations
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  IF coalesce(auth.jwt()->>'role','') <> 'service_role' THEN
    RAISE EXCEPTION 'service-role execution context required' USING errcode='42501';
  END IF;

  RETURN private.aios_kernel_authorize_invocation(p_invocation_id);
END;
$function$;

-- Remove the stray PUBLIC execute grants on the two kernel entry points that had them.
-- Only service_role (and the owning postgres role) should be able to call these.
REVOKE EXECUTE ON FUNCTION public.aios_kernel_authorize_invocation(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.aios_record_evaluation(uuid, uuid, numeric, numeric, numeric, numeric, numeric, text) FROM PUBLIC;
