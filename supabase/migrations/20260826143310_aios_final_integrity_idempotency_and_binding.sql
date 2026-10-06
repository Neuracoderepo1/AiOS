create unique index if not exists aios_invocations_org_idempotency_key_idx on public.aios_tool_invocations(organization_id,idempotency_key) where idempotency_key is not null;

create or replace function private.aios_validate_invocation_integrity() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t public.aios_tasks; a public.aios_agents; m public.aios_missions;
begin
  select * into a from public.aios_agents where id=new.agent_id;
  if a.id is null or a.organization_id<>new.organization_id then raise exception 'invocation agent organization mismatch' using errcode='23514'; end if;
  if new.task_id is not null then
    select * into t from public.aios_tasks where id=new.task_id;
    if t.id is null or t.organization_id<>new.organization_id then raise exception 'invocation task organization mismatch' using errcode='23514'; end if;
    if t.assigned_agent_id is distinct from new.agent_id then raise exception 'invocation agent does not match assigned task agent' using errcode='23514'; end if;
    if t.mission_id is not null then
      select * into m from public.aios_missions where id=t.mission_id;
      if m.id is null or m.organization_id<>new.organization_id then raise exception 'invocation mission organization mismatch' using errcode='23514'; end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_aios_validate_invocation_integrity on public.aios_tool_invocations;
create trigger trg_aios_validate_invocation_integrity before insert or update of organization_id,agent_id,task_id on public.aios_tool_invocations for each row execute function private.aios_validate_invocation_integrity();

create or replace function private.aios_validate_approval_integrity() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a public.aios_agents; t public.aios_tasks; i public.aios_tool_invocations;
begin
  if new.agent_id is not null then
    select * into a from public.aios_agents where id=new.agent_id;
    if a.id is null or a.organization_id<>new.organization_id then raise exception 'approval agent organization mismatch' using errcode='23514'; end if;
  end if;
  if new.task_id is not null then
    select * into t from public.aios_tasks where id=new.task_id;
    if t.id is null or t.organization_id<>new.organization_id then raise exception 'approval task organization mismatch' using errcode='23514'; end if;
    if new.agent_id is not null and t.assigned_agent_id is distinct from new.agent_id then raise exception 'approval agent does not match task agent' using errcode='23514'; end if;
  end if;
  if new.invocation_id is not null then
    select * into i from public.aios_tool_invocations where id=new.invocation_id;
    if i.id is null or i.organization_id<>new.organization_id then raise exception 'approval invocation organization mismatch' using errcode='23514'; end if;
    if new.agent_id is not null and i.agent_id is distinct from new.agent_id then raise exception 'approval agent does not match invocation agent' using errcode='23514'; end if;
    if new.task_id is not null and i.task_id is distinct from new.task_id then raise exception 'approval task does not match invocation task' using errcode='23514'; end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_aios_validate_approval_integrity on public.aios_approvals;
create trigger trg_aios_validate_approval_integrity before insert or update on public.aios_approvals for each row execute function private.aios_validate_approval_integrity();

revoke execute on function private.aios_validate_invocation_integrity() from public,anon,authenticated;
revoke execute on function private.aios_validate_approval_integrity() from public,anon,authenticated;
