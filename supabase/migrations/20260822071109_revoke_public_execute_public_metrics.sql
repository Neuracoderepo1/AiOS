-- Prior migration revoked EXECUTE from anon directly, but the actual grant
-- was inherited via the default PUBLIC grant (Postgres grants EXECUTE to
-- PUBLIC on function creation unless explicitly revoked). anon inherits
-- through PUBLIC, so the first revoke was a no-op for anon's actual access.
-- Revoke from PUBLIC, then re-grant to authenticated and service_role
-- explicitly so they retain access.
revoke execute on function public.aios_public_metrics() from public;
grant execute on function public.aios_public_metrics() to authenticated;
grant execute on function public.aios_public_metrics() to service_role;
