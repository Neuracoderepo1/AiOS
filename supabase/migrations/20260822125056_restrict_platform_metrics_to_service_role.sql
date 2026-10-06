-- aios_platform_metrics() aggregates counts across ALL organizations with
-- no membership/role check — any authenticated user from any org could
-- currently see platform-wide business metrics for every other org.
-- There is no "platform superadmin" concept in this schema (roles are
-- scoped per-org via aios_organization_members), so the correct fix is to
-- restrict this to service_role only — i.e. callable from trusted internal
-- tooling with the service key, never from a client-authenticated session.
REVOKE EXECUTE ON FUNCTION public.aios_platform_metrics() FROM authenticated;
