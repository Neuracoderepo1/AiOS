-- Prior migration revoked from PUBLIC only, which does not remove
-- privileges granted directly to anon/authenticated (Supabase's default
-- grants target those roles explicitly). Revoking explicitly here.

REVOKE EXECUTE ON FUNCTION public.aios_log_mission_status_audit() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.aios_log_task_status_audit() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.aios_log_tool_invocation_audit() FROM anon, authenticated;

-- aios_platform_metrics(): revoke anon entirely (unauthenticated should
-- never see platform-wide metrics). Leaving authenticated in place for
-- now — flagging for a follow-up decision on whether this should be
-- admin-only rather than any signed-in user.
REVOKE EXECUTE ON FUNCTION public.aios_platform_metrics() FROM anon;
