-- Cancellation RPC security boundary. Runs on the clean, real-PostgreSQL migration replay.
do $$
declare
  v_oid oid;
  v_def text;
  v_config text[];
begin
  select p.oid, pg_get_functiondef(p.oid), p.proconfig
    into v_oid, v_def, v_config
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'aios_cancel_mission'
     and pg_get_function_identity_arguments(p.oid) = 'p_mission_id uuid';

  if v_oid is null then
    raise exception 'public.aios_cancel_mission(uuid) is missing';
  end if;
  if not (select prosecdef from pg_proc where oid = v_oid) then
    raise exception 'cancellation RPC must remain SECURITY DEFINER';
  end if;
  if not exists (
    select 1 from unnest(coalesce(v_config, '{}'::text[])) setting
    where setting = 'search_path=""'
  ) then
    raise exception 'cancellation RPC must pin an empty search_path';
  end if;
  if has_function_privilege('anon', v_oid, 'execute')
     or has_function_privilege('service_role', v_oid, 'execute')
     or exists (select 1 from aclexplode((select proacl from pg_proc where oid = v_oid)) a
                where a.grantee = 0 and a.privilege_type = 'EXECUTE') then
    raise exception 'cancellation RPC must not be executable by anon, service_role, or PUBLIC';
  end if;
  if not has_function_privilege('authenticated', v_oid, 'execute') then
    raise exception 'authenticated must be able to invoke cancellation RPC';
  end if;
  if position('auth.uid()' in v_def) = 0
     or position('p_actor_user_id' in v_def) > 0 then
    raise exception 'cancellation actor must come from auth.uid(), never a caller-supplied UUID';
  end if;
  if position('public.aios_organization_members' in v_def) = 0
     or position('for update' in lower(v_def)) = 0 then
    raise exception 'cancellation must lock and revalidate the authenticated organization membership';
  end if;
  if position('already_terminal' in v_def) = 0
     or position('failed' in v_def) = 0
     or position('succeeded' in v_def) = 0
     or position('cancelled' in v_def) = 0 then
    raise exception 'terminal-state no-op contract is incomplete';
  end if;
  if to_regprocedure('public.aios_cancel_mission(uuid,uuid)') is not null
     or to_regprocedure('private.aios_cancel_mission(uuid,uuid)') is not null then
    raise exception 'legacy caller-supplied-actor cancellation overload remains installed';
  end if;
end
$$;

select 'ok: authenticated cancellation RPC boundary' as result;
