-- Complete restoration-role membership allowlist and durable mission completion reconciliation.
create table if not exists private.aios_restorer_member_allowlist (
  member_oid oid primary key, member_name name not null, approval_reason text not null,
  approved_at timestamptz not null default clock_timestamp(), approved_by name not null default session_user,
  admin_option boolean not null, set_option boolean not null, inherit_option boolean not null
);
alter table private.aios_restorer_member_allowlist enable row level security;
revoke all on private.aios_restorer_member_allowlist from public,anon,authenticated,service_role,aios_restorer;

-- Only adopt the migration executor's own implicit creator membership. Never adopt arbitrary existing members.
insert into private.aios_restorer_member_allowlist(member_oid,member_name,approval_reason,admin_option,set_option,inherit_option)
select r.oid,r.rolname,'implicit membership created by this migration executor',m.admin_option,m.set_option,m.inherit_option
from pg_catalog.pg_auth_members m join pg_catalog.pg_roles r on r.oid=m.member
where m.roleid='aios_restorer'::regrole and r.rolname=session_user
on conflict(member_oid) do nothing;

create or replace function private.aios_restorer_boundary_violations() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare v jsonb:='[]'::jsonb; r record; m record;
begin
  select * into r from pg_catalog.pg_roles where rolname='aios_restorer';
  if not found then return jsonb_build_array('role_missing'); end if;
  if r.rolcanlogin then v:=v||'"restorer_can_login"'::jsonb; end if;
  if r.rolinherit then v:=v||'"restorer_inherits_roles"'::jsonb; end if;
  if r.rolsuper then v:=v||'"restorer_is_superuser"'::jsonb; end if;
  if r.rolcreaterole or r.rolcreatedb or r.rolreplication or r.rolbypassrls then v:=v||'"restorer_has_extra_attributes"'::jsonb; end if;
  if exists(select 1 from pg_catalog.pg_auth_members x where x.member=r.oid) then v:=v||'"restorer_is_member_of_other_roles"'::jsonb; end if;
  for m in
    select pr.rolname,am.member,am.admin_option,am.set_option,am.inherit_option
    from pg_catalog.pg_auth_members am join pg_catalog.pg_roles pr on pr.oid=am.member
    where am.roleid=r.oid order by pr.rolname
  loop
    if not exists(select 1 from private.aios_restorer_member_allowlist al
      where al.member_oid=m.member and al.member_name=m.rolname
        and al.admin_option=m.admin_option and al.set_option=m.set_option and al.inherit_option=m.inherit_option) then
      v:=v||to_jsonb('unapproved_member:'||m.rolname);
    end if;
  end loop;
  for m in
    select al.member_name from private.aios_restorer_member_allowlist al
    where not exists(select 1 from pg_catalog.pg_auth_members am
      where am.roleid=r.oid and am.member=al.member_oid
        and am.admin_option=al.admin_option and am.set_option=al.set_option and am.inherit_option=al.inherit_option)
  loop v:=v||to_jsonb('approved_member_missing:'||m.member_name); end loop;
  for m in select rolname,oid from pg_catalog.pg_roles
    where rolname in('anon','authenticated','service_role','authenticator','supabase_auth_admin','supabase_storage_admin','supabase_functions_admin')
      and not rolsuper
  loop
    if pg_catalog.pg_has_role(m.oid,r.oid,'MEMBER') then v:=v||to_jsonb('app_role_is_member:'||m.rolname); end if;
  end loop;
  if pg_catalog.has_schema_privilege('public','private','USAGE') then v:=v||'"public_has_private_schema_usage"'::jsonb; end if;
  return v;
end
$fn$;

create or replace function private.aios_assert_restorer() returns void
language plpgsql stable security definer set search_path = '' as $fn$
declare v jsonb;
begin
  if session_user in('anon','authenticated','service_role','authenticator','supabase_auth_admin','supabase_storage_admin','supabase_functions_admin') then
    raise exception 'restoration is not available to application roles' using errcode='42501';
  end if;
  if not exists(
    select 1 from pg_catalog.pg_roles pr
    join pg_catalog.pg_auth_members am on am.member=pr.oid
    join private.aios_restorer_member_allowlist al on al.member_oid=am.member and al.member_name=pr.rolname
      and al.admin_option=am.admin_option and al.set_option=am.set_option and al.inherit_option=am.inherit_option
    where pr.rolname=session_user and am.roleid='aios_restorer'::regrole
  ) then raise exception 'restoration requires an explicitly approved session login' using errcode='42501'; end if;
  v:=private.aios_restorer_boundary_violations();
  if v<>'[]'::jsonb then raise exception 'restorer role boundary violated: %',v using errcode='42501'; end if;
end
$fn$;
revoke all on function private.aios_restorer_boundary_violations(),private.aios_assert_restorer() from public,anon,authenticated,service_role;

do $guard$
begin
  if private.aios_restorer_boundary_violations()<>'[]'::jsonb then
    raise exception 'aios_restorer complete membership allowlist is not satisfied: %',
      private.aios_restorer_boundary_violations() using errcode='42501';
  end if;
end
$guard$;

create table if not exists private.aios_mission_reconciliation_queue(
  mission_id uuid primary key references public.aios_missions(id) on delete cascade,
  requested_at timestamptz not null default clock_timestamp(), attempts integer not null default 0, last_error text
);
alter table private.aios_mission_reconciliation_queue enable row level security;
revoke all on private.aios_mission_reconciliation_queue from public,anon,authenticated,service_role;

create or replace function private.aios_enqueue_mission_reconciliation() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if new.status='completed' and old.status is distinct from new.status and new.mission_id is not null then
    insert into private.aios_mission_reconciliation_queue(mission_id) values(new.mission_id)
    on conflict(mission_id) do update set requested_at=clock_timestamp();
  end if;
  return new;
end
$fn$;
revoke all on function private.aios_enqueue_mission_reconciliation() from public,anon,authenticated,service_role;
drop trigger if exists trg_aios_enqueue_mission_reconciliation on public.aios_tasks;
create trigger trg_aios_enqueue_mission_reconciliation after update of status on public.aios_tasks
for each row execute function private.aios_enqueue_mission_reconciliation();

create or replace function private.aios_reconcile_mission_completion(p_mission_id uuid)
returns text language plpgsql security definer set search_path = '' as $fn$
declare v_status text; v_total bigint; v_incomplete bigint;
begin
  select m.status into v_status from public.aios_missions m where m.id=p_mission_id for update;
  if not found then return 'missing'; end if;
  if v_status<>'running' then return v_status; end if;
  select count(*),count(*) filter(where t.status<>'completed') into v_total,v_incomplete
    from public.aios_tasks t where t.mission_id=p_mission_id;
  if v_total>0 and v_incomplete=0 then
    update public.aios_missions set status='completed',completed_at=coalesce(completed_at,clock_timestamp())
      where id=p_mission_id and status='running';
  end if;
  select status into v_status from public.aios_missions where id=p_mission_id;
  return coalesce(v_status,'missing');
end
$fn$;

create or replace function private.aios_process_mission_reconciliation_queue(p_batch_size integer default 100)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare q record; v_status text; v_done integer:=0; v_failed integer:=0;
begin
  if p_batch_size<1 or p_batch_size>1000 then raise exception 'batch size must be between 1 and 1000' using errcode='22023'; end if;
  for q in select mission_id from private.aios_mission_reconciliation_queue order by requested_at,mission_id
    for update skip locked limit p_batch_size
  loop
    begin
      v_status:=private.aios_reconcile_mission_completion(q.mission_id);
      delete from private.aios_mission_reconciliation_queue where mission_id=q.mission_id;
      v_done:=v_done+1;
    exception when others then
      update private.aios_mission_reconciliation_queue set attempts=attempts+1,last_error=sqlerrm where mission_id=q.mission_id;
      v_failed:=v_failed+1;
    end;
  end loop;
  return jsonb_build_object('processed',v_done,'failed',v_failed);
end
$fn$;
revoke all on function private.aios_reconcile_mission_completion(uuid),private.aios_process_mission_reconciliation_queue(integer) from public,anon,authenticated;
grant execute on function private.aios_reconcile_mission_completion(uuid) to service_role;
comment on function private.aios_reconcile_mission_completion(uuid) is 'Idempotently reconciles one mission from persisted task states; terminal states are never overwritten.';
comment on function private.aios_process_mission_reconciliation_queue(integer) is 'Retries durable mission completion work; failures remain queued with diagnostics.';
select cron.schedule('aios-reconcile-mission-completions','* * * * *',$$select private.aios_process_mission_reconciliation_queue(100)$$);
