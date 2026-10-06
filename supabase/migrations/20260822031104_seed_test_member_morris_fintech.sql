insert into public.aios_organization_members (organization_id, user_id, role)
select id, 'e25d485b-6e88-4d63-a9b5-a23388714da6', 'member'
from public.aios_organizations
where name = 'Morris Fintech Labs';
