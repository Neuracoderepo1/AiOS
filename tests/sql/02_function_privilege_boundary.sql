-- Function privilege boundary, exercised with REAL client roles (SET ROLE), not just catalog introspection.
-- Complements 01_security_invariants.sql (which is unchanged). Needs no fixtures; raises on any violation.
--
-- Why this exists: 01 invariant 3 checks has_function_privilege(), which is correct, but the way it was previously
-- violated was invisible to review: `REVOKE ... FROM anon, authenticated` does nothing when EXECUTE comes from PUBLIC,
-- and a newly created function in `private` is executable by PUBLIC by default. Check A below inspects PUBLIC directly.
do $$
declare
  v text;
  calls text[] := array[
    'select private.aios_current_org_role(gen_random_uuid())',
    'select private.aios_agent_trust_explain(gen_random_uuid())',
    'select private.aios_public_metrics(gen_random_uuid())'
  ];
  q text;
  r text;
  res text;
begin
  -- A. No function in schema private may be executable by PUBLIC (explicit grant, or the default NULL ACL).
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ') into v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private'
     and (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'));
  if v is not null then raise exception 'private functions executable by PUBLIC: %', v; end if;

  -- B. The only client-executable functions in private are the RLS membership helpers, and they must stay executable.
  select string_agg(p.proname, ', ' order by p.proname) into v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private'
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));
  if v is distinct from 'aios_is_org_admin, aios_is_org_member' then
    raise exception 'unexpected client-executable private functions (expected only the two RLS helpers): %', v;
  end if;

  -- C. Real calls as anon / authenticated / service_role to the private implementations must be refused (42501).
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    foreach q in array calls loop
      begin
        execute format('set local role %I', r);
        execute q;
        execute 'reset role';
        raise exception 'role % was able to run: %', r, q;
      exception when insufficient_privilege then
        execute 'reset role';
      end;
    end loop;
  end loop;

  -- D. The public wrappers are the only boundary: callable by authenticated and service_role (no exception, and no data
  --    for an unknown org/agent), refused for anon.
  foreach r in array array['authenticated', 'service_role'] loop
    execute format('set local role %I', r);
    select public.aios_current_org_role(gen_random_uuid()) into res;
    if res is not null then execute 'reset role'; raise exception '% got a role for a random org: %', r, res; end if;
    select (public.aios_public_metrics(gen_random_uuid())::jsonb) ? 'error' into res;
    if res is distinct from 'true' then execute 'reset role'; raise exception '% got metrics for a random org', r; end if;
    select (public.aios_agent_trust_explain(gen_random_uuid()))  ? 'error' into res;
    if res is distinct from 'true' then execute 'reset role'; raise exception '% got a trust report for a random agent', r; end if;
    execute 'reset role';
  end loop;

  begin
    set local role anon;
    perform public.aios_current_org_role(gen_random_uuid());
    reset role;
    raise exception 'anon was able to call public.aios_current_org_role';
  exception when insufficient_privilege then
    reset role;
  end;
end $$;
select 'ok: function privilege boundary' as result;
