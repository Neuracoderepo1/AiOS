-- aios_platform_metrics() has no internal authorization check (unlike
-- aios_public_metrics, which gates on org membership). It currently
-- aggregates counts and averages across ALL organizations on the
-- platform, so any authenticated user — regardless of which org they
-- belong to — can see cross-tenant data. There is no platform-owner
-- role defined in this schema yet, so the safe default is to restrict
-- this to service_role only until a proper platform-admin role exists.
REVOKE EXECUTE ON FUNCTION public.aios_platform_metrics() FROM authenticated;
