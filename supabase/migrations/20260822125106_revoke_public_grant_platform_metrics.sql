-- Root cause of persistent anon/authenticated access: EXECUTE was still
-- granted to the PUBLIC pseudo-role, which anon and authenticated both
-- inherit from regardless of explicit per-role revokes. Revoking from
-- PUBLIC directly closes this for good; service_role and postgres keep
-- their explicit grants untouched.
REVOKE EXECUTE ON FUNCTION public.aios_platform_metrics() FROM PUBLIC;
