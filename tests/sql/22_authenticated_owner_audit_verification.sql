-- F-40-10: tenant-scoped authenticated owner audit verification.
-- JWT claims are set in the real-PostgreSQL test harness to exercise auth.uid();
-- this fixture is regression evidence, not production owner-session evidence.
begin;

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('22000000-0000-4000-8000-000000000001','authenticated','authenticated','f40-10-owner@aios.test','x',now(),'{}','{}',now(),now()),
  ('22000000-0000-4000-8000-000000000002','authenticated','authenticated','f40-10-member@aios.test','x',now(),'{}','{}',now(),now())
on conflict (id) do nothing;

insert into public.aios_organizations(id,name)
values
  ('22100000-0000-4000-8000-000000000001','F-40-10 owner verification'),
  ('22100000-0000-4000-8000-000000000002','F-40-10 out of scope')
on conflict (id) do nothing;

insert into public.aios_organization_members(organization_id,user_id,role)
values
  ('22100000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000001','owner'),
  ('22100000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000002','member')
on conflict (organization_id,user_id) do update set role=excluded.role;

do $acl$
begin
  if not has_function_privilege('authenticated','public.aios_audit_verify_owner(uuid)','EXECUTE') then
    raise exception 'authenticated is missing owner-verification EXECUTE';
  end if;
  if has_function_privilege('anon','public.aios_audit_verify_owner(uuid)','EXECUTE')
     or has_function_privilege('service_role','public.aios_audit_verify_owner(uuid)','EXECUTE') then
    raise exception 'anon or service_role can execute owner verification';
  end if;
end
$acl$;

set local role authenticated;
select set_config('request.jwt.claim.sub','22000000-0000-4000-8000-000000000001',true);

do $owner_call$
declare
  v_result jsonb;
begin
  v_result := public.aios_audit_verify_owner('22100000-0000-4000-8000-000000000001');
  if v_result ->> 'actor_user_id' <> '22000000-0000-4000-8000-000000000001' then
    raise exception 'owner verifier did not bind actor to auth.uid(): %',v_result;
  end if;
  if v_result ->> 'organization_id' <> '22100000-0000-4000-8000-000000000001'
     or v_result ->> 'scope' <> 'single_authorized_organization' then
    raise exception 'owner verifier returned an invalid scope: %',v_result;
  end if;
  if v_result ? 'organizations' then
    raise exception 'owner verifier leaked the global organization list';
  end if;
  if v_result ->> 'certification_grade' <> 'false' then
    raise exception 'owner verifier incorrectly claimed certification-grade evidence';
  end if;
end
$owner_call$;

-- A non-owner member must not obtain an owner verification or create an owner run.
select set_config('request.jwt.claim.sub','22000000-0000-4000-8000-000000000002',true);
do $member_denied$
declare v_state text; v_denied boolean := false;
begin
  begin
    perform public.aios_audit_verify_owner('22100000-0000-4000-8000-000000000001');
  exception when insufficient_privilege then
    get stacked diagnostics v_state = returned_sqlstate;
    v_denied := true;
  end;
  if not v_denied or v_state <> '42501' then
    raise exception 'non-owner member was not denied with 42501 (state=%)',v_state;
  end if;
end
$member_denied$;

-- Even the authorized owner cannot query a different organization without membership.
select set_config('request.jwt.claim.sub','22000000-0000-4000-8000-000000000001',true);
do $cross_tenant_denied$
declare v_state text; v_denied boolean := false;
begin
  begin
    perform public.aios_audit_verify_owner('22100000-0000-4000-8000-000000000002');
  exception when insufficient_privilege then
    get stacked diagnostics v_state = returned_sqlstate;
    v_denied := true;
  end;
  if not v_denied or v_state <> '42501' then
    raise exception 'cross-organization verification was not denied with 42501 (state=%)',v_state;
  end if;
end
$cross_tenant_denied$;

reset role;

do $recorded$
begin
  if not exists (
    select 1 from private.aios_audit_verification_runs
    where organization_id='22100000-0000-4000-8000-000000000001'
      and kind='owner'
      and actor_user_id='22000000-0000-4000-8000-000000000001'
  ) then
    raise exception 'successful owner verification was not recorded with its authenticated actor';
  end if;
  if exists (
    select 1 from private.aios_audit_verification_runs
    where organization_id in (
      '22100000-0000-4000-8000-000000000001',
      '22100000-0000-4000-8000-000000000002'
    )
      and kind='owner'
      and actor_user_id='22000000-0000-4000-8000-000000000002'
  ) then
    raise exception 'unauthorized member created an owner verification run';
  end if;
end
$recorded$;

rollback;

select 'ok: F-40-10 tenant-scoped authenticated owner audit verification' as result;
