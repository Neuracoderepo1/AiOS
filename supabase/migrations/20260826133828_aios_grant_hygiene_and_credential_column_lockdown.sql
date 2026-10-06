-- Grant hygiene: remove unnecessary PUBLIC execute grants on helper functions.
-- These were not exploitable (downstream checks / pure functions), but least-privilege
-- says PUBLIC shouldn't have them at all.
REVOKE EXECUTE ON FUNCTION public.aios_can_manage_agent(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.aios_can_manage_contract(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.aios_risk_rank(text) FROM PUBLIC;

-- Column-level lockdown: aios_tools is a global (non-org-scoped) catalog readable by
-- every authenticated user by design. credential_reference is currently unused (all NULL)
-- but if it's ever populated with an actual secret rather than a vault pointer, it would
-- otherwise be readable platform-wide. Explicitly revoke SELECT on just that column.
REVOKE SELECT (credential_reference) ON public.aios_tools FROM authenticated;

COMMENT ON COLUMN public.aios_tools.credential_reference IS
  'Must be a reference/pointer to a secret (e.g. vault key name), never the secret value itself. SELECT is revoked from authenticated at the column level — do not re-grant without moving actual secret storage elsewhere.';
