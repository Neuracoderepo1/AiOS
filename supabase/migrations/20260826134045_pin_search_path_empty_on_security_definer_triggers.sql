-- Phase 1.2 hardening: these 4 SECURITY DEFINER trigger functions already fully-qualify
-- every table reference with `public.`, so they were not actually exploitable via
-- search_path hijacking. But best practice (and the pattern aios_handle_new_user already
-- follows) is search_path = '' rather than a named schema. Pinning to empty string is a
-- pure hardening move here: built-ins resolve via pg_catalog regardless of search_path,
-- and every non-builtin identifier in these functions is already schema-qualified, so
-- there is no behavior change.

ALTER FUNCTION public.aios_enforce_agent_authority() SET search_path = '';
ALTER FUNCTION public.aios_log_mission_status_audit() SET search_path = '';
ALTER FUNCTION public.aios_log_task_status_audit() SET search_path = '';
ALTER FUNCTION public.aios_log_tool_invocation_audit() SET search_path = '';
