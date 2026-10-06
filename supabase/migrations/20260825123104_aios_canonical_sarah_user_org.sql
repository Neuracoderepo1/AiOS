begin;
insert into public.aios_agents(organization_id,agent_key,name,role,status,primary_model,trust_score,authority,metadata)
values('f327745f-c44b-4d36-8531-a80f068599c9','sarah-research-analyst','Sarah','Research & Support Analyst','idle','Claude',70,'{"risk_level":"low","allowed_tools":["support.search_tickets"],"limits":{}}'::jsonb,'{"canonical_demo":true}'::jsonb)
on conflict(organization_id,agent_key) do update set name=excluded.name,role=excluded.role,status='idle',primary_model='Claude',authority=excluded.authority;
insert into public.aios_contracts(organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active)
select organization_id,id,coalesce((select max(c.version)+1 from public.aios_contracts c where c.agent_id=aios_agents.id),1),'low','["support.search_tickets"]'::jsonb,'{}'::jsonb,true from public.aios_agents where organization_id='f327745f-c44b-4d36-8531-a80f068599c9' and agent_key='sarah-research-analyst';
update public.aios_contracts c set is_active=false where c.organization_id='f327745f-c44b-4d36-8531-a80f068599c9' and c.agent_id=(select id from public.aios_agents where organization_id='f327745f-c44b-4d36-8531-a80f068599c9' and agent_key='sarah-research-analyst') and c.version < (select max(x.version) from public.aios_contracts x where x.agent_id=c.agent_id);
update public.aios_demo_support_tickets set organization_id='f327745f-c44b-4d36-8531-a80f068599c9' where organization_id is null;
commit;
