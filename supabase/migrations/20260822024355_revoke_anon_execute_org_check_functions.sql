-- Restrict aios_is_org_admin / aios_is_org_member so unauthenticated (anon) callers
-- cannot invoke them directly via PostgREST RPC. Both rely on auth.uid(), which is
-- null for anon, so no data was leaking — but there's no reason to expose these
-- as public RPC endpoints at all. authenticated keeps EXECUTE since RLS policies
-- for logged-in users depend on these.

revoke execute on function public.aios_is_org_admin(uuid) from anon;
revoke execute on function public.aios_is_org_member(uuid) from anon;

revoke execute on function public.aios_is_org_admin(uuid) from public;
revoke execute on function public.aios_is_org_member(uuid) from public;

grant execute on function public.aios_is_org_admin(uuid) to authenticated;
grant execute on function public.aios_is_org_member(uuid) to authenticated;
