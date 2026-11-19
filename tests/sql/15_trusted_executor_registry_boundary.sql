-- The trusted executor registry is intentionally server-only.
-- No client role (including service_role) receives direct table or validator access.
-- The kernel reaches it only through the private SECURITY DEFINER authorization path.
do $$
declare
  v_table oid;
  v_rls boolean;
  v_policies integer;
  v_role text;
  v_count integer;
begin
  select c.oid,c.relrowsecurity into v_table,v_rls
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='private' and c.relname='aios_trusted_executors' and c.relkind in ('r','p');
  if v_table is null then raise exception 'private.aios_trusted_executors is missing'; end if;
  if not v_rls then raise exception 'trusted executor registry must have RLS enabled'; end if;

  select count(*) into v_policies from pg_policy where polrelid=v_table;
  if v_policies<>0 then
    raise exception 'trusted executor registry must remain deny-by-default with zero policies; found %',v_policies;
  end if;

  foreach v_role in array array['anon','authenticated','service_role'] loop
    if has_table_privilege(v_role,v_table,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
      raise exception 'role % has direct privileges on private.aios_trusted_executors',v_role;
    end if;
  end loop;

  if exists (
    select 1 from aclexplode(coalesce((select relacl from pg_class where oid=v_table),acldefault('r',(select relowner from pg_class where oid=v_table)))) a
    where a.grantee=0 and a.privilege_type in ('SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')
  ) then
    raise exception 'PUBLIC has direct privileges on private.aios_trusted_executors';
  end if;

  if has_function_privilege('anon','private.aios_validate_executor_registry(text)'::regprocedure,'EXECUTE')
     or has_function_privilege('authenticated','private.aios_validate_executor_registry(text)'::regprocedure,'EXECUTE')
     or has_function_privilege('service_role','private.aios_validate_executor_registry(text)'::regprocedure,'EXECUTE') then
    raise exception 'client/service roles must not call private.aios_validate_executor_registry directly';
  end if;

  foreach v_role in array array['anon','authenticated','service_role'] loop
    execute format('set local role %I',v_role);
    begin
      execute 'select count(*) from private.aios_trusted_executors' into v_count;
      execute 'reset role';
      raise exception 'role % directly read the trusted executor registry',v_role;
    exception when insufficient_privilege then
      execute 'reset role';
    end;
  end loop;
end $$;
select 'ok: trusted executor registry boundary' as result;
