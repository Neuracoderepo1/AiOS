-- Private functions are never a client API surface (tests/sql/01_security_invariants.sql, invariant 3).
--
-- ROOT CAUSE (verified against a from-scratch replay of all migrations AND production, which matched exactly):
--   * private.aios_agent_trust_explain(uuid) and private.aios_current_org_role(uuid) were granted to `authenticated`
--     (20260825123114) solely so the SECURITY INVOKER public.* wrappers could reach them.
--   * private.aios_public_metrics(uuid): 20260826144103 revoked only `anon, authenticated`, but the EXECUTE came through
--     PUBLIC (=X/postgres), so every role, including anon, still held it. A revoke from named roles does nothing for a
--     PUBLIC grant. (anon has no USAGE on schema private, so it was latent rather than reachable, but it is still wrong.)
--   * private.aios_touch_task_updated_at() (20261014120831) was never revoked and kept the default PUBLIC EXECUTE.
--     It is a trigger function; trigger functions are not EXECUTE-checked when they fire, so no client role needs it.
--
-- FIX: one callable boundary. The public wrappers become SECURITY DEFINER (search_path pinned to ''), so the private
-- implementations can be locked to their owner. This is behaviour-preserving: the private bodies are already
-- SECURITY DEFINER and authorise through auth.uid() / private.aios_is_org_member(), neither of which depends on the
-- role executing the one-line wrapper. Wrapper signatures, return types and the roles allowed to call them are unchanged.
--
-- Written as loops over pg_proc so every overload in either schema is covered, and fully idempotent.

do $$
declare
  fn record;
begin
  -- 1. Public wrappers: definer + pinned search_path; callable by authenticated and service_role only (never PUBLIC/anon).
  for fn in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('aios_agent_trust_explain', 'aios_current_org_role', 'aios_public_metrics')
  loop
    execute format('alter function %s security definer set search_path = %L', fn.sig, '');
    execute format('revoke all on function %s from public, anon', fn.sig);
    execute format('grant execute on function %s to authenticated, service_role', fn.sig);
  end loop;

  -- 2. Private implementations (and the trigger function): no client role, and nothing inherited through PUBLIC.
  --    The owner keeps implicit EXECUTE; pg_cron jobs and triggers run as the owner and are unaffected.
  for fn in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname in ('aios_agent_trust_explain', 'aios_current_org_role', 'aios_public_metrics',
                        'aios_touch_task_updated_at')
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', fn.sig);
  end loop;
end $$;
