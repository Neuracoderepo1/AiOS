-- Security: the audit-log functions are meant to run only as triggers
-- (fired by the executor, which does not require role EXECUTE privilege).
-- They should never be callable directly via /rest/v1/rpc/... by anon or
-- authenticated roles. Revoking EXECUTE here does not break the triggers.
REVOKE EXECUTE ON FUNCTION public.aios_log_mission_status_audit() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.aios_log_task_status_audit() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.aios_log_tool_invocation_audit() FROM PUBLIC;

-- Security: aios_platform_metrics() is currently callable by anon
-- (unauthenticated). Revoke anon access; leave authenticated access in
-- place pending a decision on whether this should be admin-gated too.
REVOKE EXECUTE ON FUNCTION public.aios_platform_metrics() FROM anon;

-- Performance: aios_tool_invocations.requested_by is an FK with no
-- covering index, and this table is the highest-write-volume table in
-- the system.
CREATE INDEX IF NOT EXISTS idx_aios_tool_invocations_requested_by
  ON public.aios_tool_invocations (requested_by);
