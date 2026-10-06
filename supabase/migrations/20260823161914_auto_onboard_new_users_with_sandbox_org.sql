-- Without this, a real visitor could sign up but would hit "not a member of
-- any organization" on every real endpoint (launch-mission, execute-task,
-- founder console). This makes signup itself provision a real, usable sandbox:
-- an organization, an owner membership, and one working agent with the same
-- contract shape as every other agent in the system.

create or replace function public.aios_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org_id uuid;
begin
  insert into public.aios_organizations (name)
  values (coalesce(new.email, 'New user') || '''s Sandbox')
  returning id into v_org_id;

  insert into public.aios_organization_members (organization_id, user_id, role)
  values (v_org_id, new.id, 'owner');

  insert into public.aios_agents (organization_id, agent_key, name, role, status, trust_score, authority)
  values (
    v_org_id,
    'sandbox-analyst-' || substr(new.id::text, 1, 8),
    'Sandbox Analyst',
    'Research Analyst',
    'idle',
    80.0,
    jsonb_build_object('risk_level', 'low', 'allowed_tools', jsonb_build_array('Python','Web','Documents'), 'limits', '{}'::jsonb)
  );

  return new;
end;
$$;

drop trigger if exists aios_on_auth_user_created on auth.users;
create trigger aios_on_auth_user_created
after insert on auth.users
for each row execute function public.aios_handle_new_user();
