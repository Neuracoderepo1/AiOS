-- F-40-08: real PostgreSQL identity and status-boundary regression.
-- The trusted legacy seed is performed as the migration owner (postgres/supabase_admin);
-- all denied client writes run under the authenticated database role and a real JWT subject.
begin;

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '21000000-0000-4000-8000-000000000001',
  'authenticated','authenticated','f40-08-member@aios.test','x',now(),
  '{}','{}',now(),now()
) on conflict (id) do nothing;

insert into public.aios_organizations(id,name)
values ('21100000-0000-4000-8000-000000000001','F-40-08 status boundary')
on conflict (id) do nothing;

insert into public.aios_organization_members(organization_id,user_id,role)
values (
  '21100000-0000-4000-8000-000000000001',
  '21000000-0000-4000-8000-000000000001',
  'owner'
)
on conflict (organization_id,user_id) do update set role=excluded.role;

-- Explicit trusted migration/restore path. This must never run as authenticated,
-- anon, or service_role; the CHECK constraint evaluates the effective database role.
do $trusted_seed$
begin
  if current_user not in ('postgres','supabase_admin') then
    raise exception 'trusted legacy fixture requires postgres/supabase_admin, got %', current_user;
  end if;
end
$trusted_seed$;

insert into public.aios_missions(id,organization_id,title,objective,status,completed_at)
values (
  '21200000-0000-4000-8000-000000000001',
  '21100000-0000-4000-8000-000000000001',
  'trusted legacy succeeded',
  'fixture',
  'succeeded',
  now()
);

insert into public.aios_missions(id,organization_id,title,objective,status)
values (
  '21200000-0000-4000-8000-000000000002',
  '21100000-0000-4000-8000-000000000001',
  'active parent',
  'fixture',
  'queued'
);

set local role authenticated;
select set_config('request.jwt.claim.sub','21000000-0000-4000-8000-000000000001',true);

-- Authenticated organization members may create ordinary missions, but cannot
-- create a succeeded mission, even though the existing RLS INSERT policy permits
-- member mission creation.
do $authenticated_mission$
declare v_state text; v_denied boolean := false;
begin
  begin
    insert into public.aios_missions(id,organization_id,title,objective,status)
    values (
      '21200000-0000-4000-8000-000000000003',
      '21100000-0000-4000-8000-000000000001',
      'client forged succeeded',
      'must be denied',
      'succeeded'
    );
  exception when check_violation then
    get stacked diagnostics v_state = returned_sqlstate;
    v_denied := true;
  end;
  if not v_denied or v_state <> '23514' then
    raise exception 'authenticated succeeded mission INSERT was not rejected by the seed-only constraint (state=%)',v_state;
  end if;

  insert into public.aios_missions(id,organization_id,title,objective,status)
  values (
    '21200000-0000-4000-8000-000000000004',
    '21100000-0000-4000-8000-000000000001',
    'ordinary client mission',
    'positive control',
    'queued'
  );
end
$authenticated_mission$;

-- Unknown task statuses are rejected by the closed status constraint, independently
-- of the parent gate. The same check applies when the parent is terminal.
do $task_status$
declare v_state text; v_denied boolean;
begin
  v_denied := false; v_state := null;
  begin
    insert into public.aios_tasks(id,organization_id,mission_id,title,status)
    values (
      '21300000-0000-4000-8000-000000000001',
      '21100000-0000-4000-8000-000000000001',
      '21200000-0000-4000-8000-000000000002',
      'unknown on active parent',
      'pending'
    );
  exception when check_violation then
    get stacked diagnostics v_state = returned_sqlstate;
    v_denied := true;
  end;
  if not v_denied or v_state <> '23514' then
    raise exception 'unknown task status on active parent was not rejected (state=%)',v_state;
  end if;

  v_denied := false; v_state := null;
  begin
    insert into public.aios_tasks(id,organization_id,mission_id,title,status)
    values (
      '21300000-0000-4000-8000-000000000002',
      '21100000-0000-4000-8000-000000000001',
      '21200000-0000-4000-8000-000000000001',
      'unknown on succeeded parent',
      'pending'
    );
  exception when check_violation then
    get stacked diagnostics v_state = returned_sqlstate;
    v_denied := true;
  end;
  if not v_denied or v_state <> '23514' then
    raise exception 'unknown task status under succeeded parent was not rejected (state=%)',v_state;
  end if;

  -- A known live state under succeeded must reach and be rejected by the original
  -- terminal-parent gate, not merely by the status constraint.
  v_denied := false; v_state := null;
  begin
    insert into public.aios_tasks(id,organization_id,mission_id,title,status)
    values (
      '21300000-0000-4000-8000-000000000003',
      '21100000-0000-4000-8000-000000000001',
      '21200000-0000-4000-8000-000000000001',
      'live task under succeeded parent',
      'queued'
    );
  exception when insufficient_privilege then
    get stacked diagnostics v_state = returned_sqlstate;
    v_denied := true;
  end;
  if not v_denied or v_state <> '42501' then
    raise exception 'live task under succeeded parent bypassed the existing gate (state=%)',v_state;
  end if;

  -- Positive control: a valid queued task under an active parent remains allowed.
  insert into public.aios_tasks(id,organization_id,mission_id,title,status)
  values (
    '21300000-0000-4000-8000-000000000004',
    '21100000-0000-4000-8000-000000000001',
    '21200000-0000-4000-8000-000000000002',
    'valid queued task',
    'queued'
  );
end
$task_status$;

reset role;
rollback;

select 'ok: F-40-08 authenticated mission and task status boundaries' as result;
