-- F-2: isolate stale-task recovery by mission subtree and by record.
-- Lock-only phase one remains globally ordered and completes before any audit write.
-- A failed subtree is rolled back to its savepoint, deferred as a unit, and does not block other missions.
create table if not exists private.aios_task_reaper_deferred (
  task_id uuid primary key references public.aios_tasks(id) on delete cascade,
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default clock_timestamp(),
  last_sqlstate text,
  last_error text,
  updated_at timestamptz not null default clock_timestamp()
);
alter table private.aios_task_reaper_deferred enable row level security;
revoke all on private.aios_task_reaper_deferred from public, anon, authenticated, service_role;

create or replace function private.aios_reap_stale_tasks(p_max_age interval DEFAULT '00:10:00'::interval)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $body$
declare
  r record;
  v_ids uuid[] := '{}'::uuid[];
  v_failed_missions uuid[] := '{}'::uuid[];
  v_failed_tasks uuid[] := '{}'::uuid[];
  v_quarantined_tasks uuid[] := '{}'::uuid[];
  v_orgs uuid[] := '{}'::uuid[];
  inv record;
  v_failed int := 0;
  v_blocked int := 0;
  v_skipped int := 0;
  v_deferred int := 0;
  v_quarantined int := 0;
  v_lock_sqlstate text;
  v_lock_error text;
  v_stage text;
  v_note text;
  v_outcome text;
  v_task_id uuid;
  v_mission_id uuid;
  v_has_inv boolean;
  v_task_updated boolean;
begin
  if p_max_age is null or p_max_age < interval '0' then
    raise exception 'max age must be non-negative' using errcode = '22023';
  end if;

  -- Freeze candidates. A deferred task is eligible only after its bounded backoff expires.
  select coalesce(array_agg(c.id order by c.updated_at, c.id), '{}'::uuid[])
    into v_ids
  from (
    select t.id, t.updated_at
    from public.aios_tasks t
    where t.status = 'running'
      and t.updated_at < clock_timestamp() - p_max_age
      and not exists (
        select 1 from private.aios_task_reaper_deferred d
        where d.task_id = t.id and d.next_attempt_at > clock_timestamp()
      )
    order by t.updated_at, t.id
  ) c;

  if cardinality(v_ids) = 0 then
    return jsonb_build_object('failed',0,'blocked_pending_approval',0,
      'skipped_needs_operator',0,'deferred',0,'quarantined',0,'max_age',p_max_age::text);
  end if;

  select coalesce(array_agg(distinct t.organization_id order by t.organization_id), '{}'::uuid[])
    into v_orgs from public.aios_tasks t where t.id = any(v_ids);

  -- PHASE 1A: acquire every mission subtree in deterministic order. Each subtree
  -- is a savepoint. A failed subtree releases its partial row locks and is deferred
  -- without preventing later missions from being locked.
  for r in
    select distinct t.mission_id
    from public.aios_tasks t
    where t.id = any(v_ids) and t.mission_id is not null
    order by t.mission_id
  loop
    begin
      perform private.aios_lock_mission_subtree(r.mission_id);
    exception when others then
      if private.aios_is_lock_conflict(sqlstate) then
        v_failed_missions := array_append(v_failed_missions, r.mission_id);
        v_lock_sqlstate := sqlstate;
        v_lock_error := sqlerrm;
      else
        -- A structural failure in a subtree is not safe to retry forever as a
        -- transient lock. Quarantine every candidate in that subtree.
        v_quarantined_tasks := v_quarantined_tasks || coalesce((
          select array_agg(t.id) from public.aios_tasks t
          where t.id = any(v_ids) and t.mission_id = r.mission_id
        ), '{}'::uuid[]);
      end if;
    end;
  end loop;

  -- Tasks without a mission have no subtree; lock them individually under savepoints.
  for r in
    select t.id from public.aios_tasks t
    where t.id = any(v_ids) and t.mission_id is null
    order by t.id
  loop
    begin
      perform 1 from public.aios_tasks t where t.id = r.id for update;
      if not found then v_failed_tasks := array_append(v_failed_tasks,r.id); end if;
    exception when others then
      if private.aios_is_lock_conflict(sqlstate) then
        v_failed_tasks := array_append(v_failed_tasks,r.id);
        v_lock_sqlstate := sqlstate;
        v_lock_error := sqlerrm;
      else
        v_quarantined_tasks := array_append(v_quarantined_tasks,r.id);
      end if;
    end;
  end loop;

  -- Audit locks are always last. No later row-lock acquisition is permitted.
  perform private.aios_prelock_audit_organizations(v_orgs);

  -- Phase 1 dispositions are persisted only after all row locks have been attempted.
  foreach v_task_id in array v_failed_tasks loop
    insert into private.aios_task_reaper_deferred(task_id,attempts,next_attempt_at,last_sqlstate,last_error,updated_at)
    values (v_task_id,1,clock_timestamp()+interval '2 seconds',coalesce(v_lock_sqlstate,'55P03'),coalesce(v_lock_error,'task row lock unavailable'),clock_timestamp())
    on conflict(task_id) do update set
      attempts=private.aios_task_reaper_deferred.attempts+1,
      next_attempt_at=clock_timestamp()+make_interval(secs=>least(300,power(2,least(private.aios_task_reaper_deferred.attempts+1,8))::integer)),
      last_sqlstate=excluded.last_sqlstate,last_error=excluded.last_error,updated_at=clock_timestamp();
    v_deferred := v_deferred+1;
  end loop;

  foreach v_mission_id in array v_failed_missions loop
    for r in
      select t.id from public.aios_tasks t
      where t.id = any(v_ids) and t.mission_id = v_mission_id
    loop
      insert into private.aios_task_reaper_deferred(task_id,attempts,next_attempt_at,last_sqlstate,last_error,updated_at)
      values (r.id,1,clock_timestamp()+interval '2 seconds',coalesce(v_lock_sqlstate,'55P03'),coalesce(v_lock_error,'mission subtree lock unavailable'),clock_timestamp())
      on conflict(task_id) do update set
        attempts=private.aios_task_reaper_deferred.attempts+1,
        next_attempt_at=clock_timestamp()+make_interval(secs=>least(300,power(2,least(private.aios_task_reaper_deferred.attempts+1,8))::integer)),
        last_sqlstate=excluded.last_sqlstate,last_error=excluded.last_error,updated_at=clock_timestamp();
      v_deferred := v_deferred+1;
    end loop;
  end loop;

  foreach v_task_id in array v_quarantined_tasks loop
    select t.organization_id into v_orgs[1] from public.aios_tasks t where t.id=v_task_id;
    insert into public.aios_backlog_dispositions
      (organization_id,entity_type,entity_id,classification,disposition,rationale,decided_by)
    values (v_orgs[1],'task',v_task_id,'needs_owner_review','manual_review',
      'Stale-task reaper could not safely acquire the task or mission lock subtree; task left unchanged for owner review.',
      'job:aios_reap_stale_tasks')
    on conflict do nothing;
    v_quarantined := v_quarantined+1;
  end loop;

  -- PHASE 2: each task transition is an independent subtransaction. A bad row
  -- cannot roll back another task's recovery or its audit event.
  for r in
    select t.id,t.organization_id,t.mission_id
    from public.aios_tasks t
    where t.id = any(v_ids)
      and t.status='running'
      and t.updated_at < clock_timestamp()-p_max_age
      and (t.mission_id is null or not (t.mission_id = any(v_failed_missions)))
      and not (t.id = any(v_failed_tasks))
      and not (t.id = any(v_quarantined_tasks))
    order by t.updated_at,t.id
  loop
    begin
      v_outcome := 'unchanged';
      select i.id,i.status into inv
      from public.aios_tool_invocations i
      where i.task_id=r.id and i.organization_id=r.organization_id
      order by i.created_at desc,i.id desc limit 1;
      v_has_inv := found;

      if v_has_inv and inv.status='requires_approval' then
        update public.aios_tasks set status='blocked_pending_approval'
          where id=r.id and status='running';
        if r.mission_id is not null then
          update public.aios_missions set status='blocked_pending_approval'
          where id=r.mission_id and status='running';
        end if;
        v_blocked:=v_blocked+1;
        v_outcome:='blocked';
      elsif v_has_inv and inv.status not in ('succeeded','failed','denied') then
        v_skipped:=v_skipped+1;
        v_outcome:='skipped';
      else
        if not v_has_inv then
          v_stage:='before_invocation';
          v_note:='Task stalled before any tool invocation was recorded (model proposal stage). No tool was executed.';
        elsif inv.status='succeeded' then
          v_stage:='final_analysis';
          v_note:='Tool already succeeded; task stalled during final analysis. Tool result is preserved on the invocation and was not re-executed.';
        else
          v_stage:='invocation_'||inv.status;
          v_note:='Invocation reached terminal state '||inv.status||' but the task was not closed.';
        end if;

        update public.aios_tasks
        set status='failed',failed_stage=v_stage,last_error=v_note,
            result=coalesce(result,'{}'::jsonb)||jsonb_build_object(
              'error','stale_task_reaped','failed_stage',v_stage,
              'invocation_id',case when v_has_inv then inv.id else null end,'note',v_note)
        where id=r.id and status='running';
        v_task_updated := found;

        if v_task_updated and r.mission_id is not null then
          update public.aios_missions m set status='failed',completed_at=now()
          where m.id=r.mission_id and m.status='running'
            and not exists(select 1 from public.aios_tasks s where s.mission_id=m.id
              and s.status in ('queued','assigned','ready','running','approved','blocked_pending_approval'));
        end if;
        delete from private.aios_task_reaper_deferred where task_id=r.id;
        v_failed:=v_failed+1;
        v_outcome:='reaped';
      end if;

      if v_outcome in ('blocked','skipped') then
        delete from private.aios_task_reaper_deferred where task_id=r.id;
      end if;
    exception when others then
      if private.aios_is_lock_conflict(sqlstate) then
        insert into private.aios_task_reaper_deferred(task_id,attempts,next_attempt_at,last_sqlstate,last_error,updated_at)
        values (r.id,1,clock_timestamp()+interval '2 seconds',sqlstate,sqlerrm,clock_timestamp())
        on conflict(task_id) do update set
          attempts=private.aios_task_reaper_deferred.attempts+1,
          next_attempt_at=clock_timestamp()+make_interval(secs=>least(300,power(2,least(private.aios_task_reaper_deferred.attempts+1,8))::integer)),
          last_sqlstate=excluded.last_sqlstate,last_error=excluded.last_error,updated_at=clock_timestamp();
        v_deferred:=v_deferred+1;
      else
        insert into public.aios_backlog_dispositions
          (organization_id,entity_type,entity_id,classification,disposition,rationale,decided_by)
        values (r.organization_id,'task',r.id,'needs_owner_review','manual_review',
          'Stale-task recovery failed safely with SQLSTATE '||sqlstate||'; task transition rolled back and requires owner review. '||left(sqlerrm,500),
          'job:aios_reap_stale_tasks')
        on conflict do nothing;
        v_quarantined:=v_quarantined+1;
      end if;
    end;
  end loop;

  return jsonb_build_object('failed',v_failed,'blocked_pending_approval',v_blocked,
    'skipped_needs_operator',v_skipped,'deferred',v_deferred,'quarantined',v_quarantined,
    'max_age',p_max_age::text);
end;
$body$;

comment on table private.aios_task_reaper_deferred is
  'Transient stale-task reaper lock failures; bounded exponential retry, never a permanent disposition.';
comment on function private.aios_reap_stale_tasks(interval) is
  'Per-mission-subtree and per-task isolated stale-task recovery. Transient lock conflicts defer; invariant failures quarantine; audit locks are acquired after all row-lock attempts.';
