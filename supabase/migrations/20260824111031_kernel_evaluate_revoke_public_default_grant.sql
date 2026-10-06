
-- Postgres grants EXECUTE to PUBLIC by default on function creation, so the
-- earlier "revoke from anon" alone did nothing: anon still executed via the
-- PUBLIC grant. Revoke PUBLIC explicitly and re-grant only to the roles that
-- should actually call this (authenticated app users; service_role for
-- edge functions/admin use).
revoke execute on function public.aios_kernel_evaluate(uuid, uuid, text, text, numeric, integer, jsonb) from public;
grant execute on function public.aios_kernel_evaluate(uuid, uuid, text, text, numeric, integer, jsonb) to authenticated;
