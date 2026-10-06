-- Supabase's default privileges auto-grant EXECUTE to anon/authenticated/
-- service_role on function creation (separate from the PUBLIC pseudo-role),
-- so the drop/create in the prior migration re-added anon access despite
-- revoking from PUBLIC. Explicitly revoking from anon here.
revoke execute on function public.aios_public_metrics(uuid) from anon;
