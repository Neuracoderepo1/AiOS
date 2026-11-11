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
declare v_org uuid; v_mission uuid; v_task uuid; v_status text; v_count bigint;
begin
  insert into public.aios_organizations(name) values('mission-reconcile-test') returning id into v_org;
  insert into public.aios_missions(organization_id,title,objective,status) values(v_org,'mission-reconcile-test','durable queue regression','running') returning id into v_mission;
  insert into public.aios_tasks(organization_id,mission_id,title,instructions,status) values(v_org,v_mission,'task-reconcile-test','fixture','running') returning id into v_task;
  update public.aios_tasks set status='completed' where id=v_task and status='running';
  select count(*) into v_count from private.aios_mission_reconciliation_queue where mission_id=v_mission;
  if v_count<>1 then raise exception 'completion trigger did not enqueue mission'; end if;
  select private.aios_reconcile_mission_completion(v_mission) into v_status;
  if v_status<>'completed' then raise exception 'expected completed, got %',v_status; end if;
  update public.aios_missions set status='cancelled' where id=v_mission;
  select private.aios_reconcile_mission_completion(v_mission) into v_status;
  if v_status<>'cancelled' then raise exception 'terminal mission overwritten: %',v_status; end if;
  perform private.aios_process_mission_reconciliation_queue(100);
  select count(*) into v_count from private.aios_mission_reconciliation_queue where mission_id=v_mission;
  if v_count<>0 then raise exception 'queue row not drained'; end if;
end
$test$;
rollback;
