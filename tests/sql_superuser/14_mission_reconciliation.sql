\set ON_ERROR_STOP on
begin;
do $privileges$
begin
  if not has_function_privilege('service_role','public.aios_reconcile_mission_completion(uuid)','EXECUTE') then
    raise exception 'service_role cannot invoke the public reconciler RPC';
  end if;
  if has_function_privilege('anon','public.aios_reconcile_mission_completion(uuid)','EXECUTE')
     or has_function_privilege('authenticated','public.aios_reconcile_mission_completion(uuid)','EXECUTE') then
    raise exception 'untrusted role can invoke the public reconciler RPC';
  end if;
end
$privileges$;
do $test$
declare
  v_org uuid; v_mission uuid; v_task uuid; v_terminal_mission uuid; v_status text; v_count bigint;
begin
  insert into public.aios_organizations(name) values('mission-reconcile-test') returning id into v_org;
  insert into public.aios_missions(organization_id,title,objective,status)
    values(v_org,'mission-reconcile-test','durable queue regression','running') returning id into v_mission;
  insert into public.aios_tasks(organization_id,mission_id,title,instructions,status)
    values(v_org,v_mission,'task-reconcile-test','fixture','running') returning id into v_task;

  -- The queue hook is tested independently of the task guard's separate succeeded-invocation requirement.
  -- Only that one guard is disabled in this rolled-back superuser fixture; audit and queue triggers remain enabled.
  alter table public.aios_tasks disable trigger trg_aios_task_status_guard;
  update public.aios_tasks set status='completed' where id=v_task and status='running';
  alter table public.aios_tasks enable trigger trg_aios_task_status_guard;

  select count(*) into v_count from private.aios_mission_reconciliation_queue where mission_id=v_mission;
  if v_count<>1 then raise exception 'completion trigger did not durably enqueue mission'; end if;
  select private.aios_reconcile_mission_completion(v_mission) into v_status;
  if v_status<>'completed' then raise exception 'expected completed, got %',v_status; end if;
  select status into v_status from public.aios_missions where id=v_mission;
  if v_status<>'completed' then raise exception 'mission status did not converge'; end if;

  -- A separately terminal mission must remain terminal when stale queue work is retried.
  insert into public.aios_missions(organization_id,title,objective,status)
    values(v_org,'terminal-mission-test','must remain cancelled','cancelled') returning id into v_terminal_mission;
  insert into private.aios_mission_reconciliation_queue(mission_id) values(v_terminal_mission);
  select private.aios_reconcile_mission_completion(v_terminal_mission) into v_status;
  if v_status<>'cancelled' then raise exception 'terminal mission overwritten: %',v_status; end if;

  if not exists(select 1 from cron.job where jobname='aios-reconcile-mission-completions') then
    raise exception 'mission reconciliation cron job is not registered';
  end if;
  perform private.aios_process_mission_reconciliation_queue(100);
  select count(*) into v_count from private.aios_mission_reconciliation_queue
    where mission_id in(v_mission,v_terminal_mission);
  if v_count<>0 then raise exception 'queue processor did not drain successful work'; end if;
  select status into v_status from public.aios_missions where id=v_terminal_mission;
  if v_status<>'cancelled' then raise exception 'queue retry changed terminal mission to %',v_status; end if;
end
$test$;
rollback;
