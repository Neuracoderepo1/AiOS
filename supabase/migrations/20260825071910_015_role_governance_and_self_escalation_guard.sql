
-- Development 7: role-based governance. Extends the existing owner/admin/
-- member model (already correctly used by aios_is_org_admin and the two
-- edge functions) with operator/viewer/auditor as recognized values, plus
-- the helper functions the directive asks for, plus closes a confirmed
-- self-escalation path: an 'admin' could set their own role to 'owner' via
-- a plain UPDATE, since the existing policy only checked "is the caller an
-- admin of this org", never "is the caller changing their own row".

alter table public.aios_organization_members
  add constraint aios_org_members_role_check
  check (role in ('owner','admin','operator','viewer','auditor','member'));

create or replace function public.aios_current_org_role(org_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from public.aios_organization_members where organization_id = org_id and user_id = auth.uid();
$$;

create or replace function public.aios_can_manage_agent(org_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select aios_is_org_admin(org_id); -- agents/contracts: owner+admin only, per Development 1/2
$$;

create or replace function public.aios_can_manage_contract(org_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select aios_is_org_admin(org_id);
$$;

create or replace function public.aios_can_approve(org_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select aios_is_org_admin(org_id); -- matches review-approval's existing check
$$;

-- Self-escalation guard: a user may never change their own role. Someone
-- else with admin rights must do it. This is independent of (and layered
-- on top of) the existing aios_is_org_admin requirement on UPDATE.
create or replace function public.aios_prevent_self_role_change()
returns trigger language plpgsql as $$
begin
  if new.user_id = auth.uid() and new.role is distinct from old.role then
    raise exception 'you cannot change your own organization role';
  end if;
  return new;
end; $$;

drop trigger if exists trg_prevent_self_role_change on public.aios_organization_members;
create trigger trg_prevent_self_role_change before update on public.aios_organization_members
  for each row execute function public.aios_prevent_self_role_change();

grant execute on function public.aios_current_org_role(uuid) to authenticated;
grant execute on function public.aios_can_manage_agent(uuid) to authenticated;
grant execute on function public.aios_can_manage_contract(uuid) to authenticated;
grant execute on function public.aios_can_approve(uuid) to authenticated;
