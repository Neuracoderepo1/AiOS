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

-- Durable quarantine is separate from transient retry/backoff state.
create table if not exists private.aios_task_reaper_quarantine (
  task_id uuid primary key references public.aios_tasks(id) on delete cascade,
  organization_id uuid not null,
  reason text not null,
  sqlstate text,
  created_at timestamptz not null default clock_timestamp(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id),
  resolution_note text,
  check ((resolved_at is null and resolved_by is null and resolution_note is null)
      or (resolved_at is not null and resolved_by is not null and resolution_note is not null))
);
alter table private.aios_task_reaper_quarantine enable row level security;
revoke all on private.aios_task_reaper_quarantine from public, anon, authenticated, service_role;

create or replace function public.aios_resolve_task_reaper_quarantine(
  p_task_id uuid, p_resolution_note text
) returns jsonb language plpgsql security definer set search_path = '' as $resolve$
declare v_org uuid; v_actor uuid := auth.uid(); v_rows integer;
begin
  if v_actor is null then raise exception 'authenticated owner identity required' using errcode = '42501'; end if;
  if p_resolution_note is null or length(btrim(p_resolution_note)) < 12 then
    raise exception 'resolution note must contain at least 12 characters' using errcode = '22023';
  end if;
  -- Authorize against the task's organization before revealing whether a quarantine exists.
  select t.organization_id into v_org from public.aios_tasks t where t.id=p_task_id;
  if not found then raise exception 'task not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.aios_organization_members m
    where m.organization_id=v_org and m.user_id=v_actor
      and m.role::text in ('owner','admin','administrator')) then
    raise exception 'organization owner/admin authorization required' using errcode = '42501';
  end if;
  perform 1 from private.aios_task_reaper_quarantine q
    where q.task_id=p_task_id and q.resolved_at is null for update;
  if not found then raise exception 'active task quarantine not found' using errcode = 'P0002'; end if;
  update private.aios_task_reaper_quarantine set resolved_at=clock_timestamp(),
    resolved_by=v_actor,resolution_note=btrim(p_resolution_note)
    where task_id=p_task_id and resolved_at is null;
  get diagnostics v_rows=row_count;
  if v_rows<>1 then raise exception 'quarantine changed concurrently' using errcode = '40001'; end if;
  -- Owner resolution clears stale transient backoff so the next scheduled run can re-evaluate immediately.
  delete from private.aios_task_reaper_deferred where task_id=p_task_id;
  insert into public.aios_backlog_dispositions
    (organization_id,entity_type,entity_id,classification,disposition,rationale,decided_by)
  values (v_org,'task',p_task_id,'owner_decision','owner_decision_retain',
    'Authorized owner/admin released stale-task quarantine. '||btrim(p_resolution_note),
    'owner:'||v_actor::text) on conflict do nothing;
  return jsonb_build_object('task_id',p_task_id,'quarantine_resolved',true,'resolved_by',v_actor);
end
$resolve$;
revoke all on function public.aios_resolve_task_reaper_quarantine(uuid,text) from public, anon;
grant execute on function public.aios_resolve_task_reaper_quarantine(uuid,text) to authenticated;

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
  v_failed_orgs uuid[] := '{}'::uuid[];
  v_quarantined_tasks uuid[] := '{}'::uuid[];
  v_orgs uuid[] := '{}'::uuid[];
  inv record;
  v_failed int := 0;
  v_blocked int := 0;
  v_skipped int := 0;
  v_deferred int := 0;
  v_quarantined int := 0;
  -- Per-task diagnostics: task UUID -> {sqlstate,error}. Never reuse a shared
  -- last-error variable across independent lock attempts.
  v_deferred_diag jsonb := '{}'::jsonb;
  v_stage text;
  v_note text;
  v_outcome text;
  v_task_id uuid;
  v_mission_id uuid;
  v_has_inv boolean;
  v_task_updated boolean;
  v_org_id uuid;
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
      and not exists (select 1 from private.aios_task_reaper_quarantine q where q.task_id=t.id and q.resolved_at is null)
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
        for v_task_id in
          select t.id from public.aios_tasks t
          where t.id = any(v_ids) and t.mission_id = r.mission_id
        loop
          v_deferred_diag := v_deferred_diag || jsonb_build_object(v_task_id::text,
            jsonb_build_object('sqlstate',sqlstate,'error',sqlerrm));
        end loop;
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
    exception when others then
      if private.aios_is_lock_conflict(sqlstate) then
        v_failed_tasks := array_append(v_failed_tasks,r.id);
        v_deferred_diag := v_deferred_diag || jsonb_build_object(r.id::text,
          jsonb_build_object('sqlstate',sqlstate,'error',sqlerrm));
      else
        v_quarantined_tasks := array_append(v_quarantined_tasks,r.id);
      end if;
    end;
  end loop;

  -- Audit locks are always last. Acquire them in UUID order with per-organization
  -- savepoints. If one org's audit lock is unavailable, defer that org's candidates;
  -- never let it abort unrelated organizations.
  for r in select x.organization_id from unnest(v_orgs) as x(organization_id)
           where x.organization_id is not null order by x.organization_id
  loop
    begin
      -- Match private.aios_audit_append() exactly, but never wait behind another
      -- organization's audit writer. A false result is a transient 55P03-style
      -- lock-unavailable condition, not a SQL exception.
      if not pg_catalog.pg_try_advisory_xact_lock(
        pg_catalog.hashtextextended(coalesce(r.organization_id::text,''),0)
      ) then
        v_failed_orgs := array_append(v_failed_orgs,r.organization_id);
        for v_task_id in
          select t.id from public.aios_tasks t
          where t.id = any(v_ids) and t.organization_id = r.organization_id
        loop
          if not (v_deferred_diag ? v_task_id::text) then
            v_deferred_diag := v_deferred_diag || jsonb_build_object(v_task_id::text,
              -- pg_try_advisory_xact_lock returns boolean and raises no SQLSTATE on false.
              -- Store NULL rather than inventing a PostgreSQL error code.
              jsonb_build_object('sqlstate',null,'error',
                'organization audit advisory lock unavailable (pg_try_advisory_xact_lock returned false)'));
          end if;
        end loop;
      end if;
    exception when others then
      if private.aios_is_lock_conflict(sqlstate) then
        v_failed_orgs := array_append(v_failed_orgs,r.organization_id);
        for v_task_id in
          select t.id from public.aios_tasks t
          where t.id = any(v_ids) and t.organization_id = r.organization_id
        loop
          if not (v_deferred_diag ? v_task_id::text) then
            v_deferred_diag := v_deferred_diag || jsonb_build_object(v_task_id::text,
              jsonb_build_object('sqlstate',sqlstate,'error',sqlerrm));
          end if;
        end loop;
      else
        raise;
      end if;
    end;
  end loop;

  -- Persist each transient failure with its own SQLSTATE and message. This private
  -- queue has no public audit/task/mission triggers; orgs without the audit lock
  -- are excluded from every public transition below.
  for r in
    select d.key::uuid as task_id,d.value as diagnostic
    from jsonb_each(v_deferred_diag) d
    order by d.key
  loop
    insert into private.aios_task_reaper_deferred(task_id,attempts,next_attempt_at,last_sqlstate,last_error,updated_at)
    values (r.task_id,1,clock_timestamp()+interval '2 seconds',
      r.diagnostic->>'sqlstate',r.diagnostic->>'error',clock_timestamp())
    on conflict(task_id) do update set
      attempts=private.aios_task_reaper_deferred.attempts+1,
      next_attempt_at=clock_timestamp()+make_interval(secs=>least(300,power(2,least(private.aios_task_reaper_deferred.attempts+1,8))::integer)),
      last_sqlstate=excluded.last_sqlstate,last_error=excluded.last_error,updated_at=clock_timestamp();
    v_deferred := v_deferred+1;
  end loop;

  -- Phase 1 dispositions are persisted only after all row locks have been attempted.

  foreach v_task_id in array v_quarantined_tasks loop
    select t.organization_id into v_org_id from public.aios_tasks t where t.id=v_task_id;
    if v_org_id = any(v_failed_orgs) then continue; end if;
    insert into private.aios_task_reaper_quarantine(task_id,organization_id,reason,sqlstate)
    values (v_task_id,v_org_id,'Structural failure acquiring stale-task mission/task lock subtree',null)
    on conflict(task_id) do update set organization_id=excluded.organization_id,reason=excluded.reason,
      sqlstate=excluded.sqlstate,created_at=clock_timestamp(),resolved_at=null,resolved_by=null,resolution_note=null;
    delete from private.aios_task_reaper_deferred where task_id=v_task_id;
    insert into public.aios_backlog_dispositions
      (organization_id,entity_type,entity_id,classification,disposition,rationale,decided_by)
    values (v_org_id,'task',v_task_id,'needs_owner_review','manual_review',
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
      and not (t.organization_id = any(v_failed_orgs))
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
        insert into private.aios_task_reaper_quarantine(task_id,organization_id,reason,sqlstate)
        values (r.id,r.organization_id,'Stale-task transition invariant failure: '||left(sqlerrm,500),sqlstate)
        on conflict(task_id) do update set organization_id=excluded.organization_id,reason=excluded.reason,
          sqlstate=excluded.sqlstate,created_at=clock_timestamp(),resolved_at=null,resolved_by=null,resolution_note=null;
        delete from private.aios_task_reaper_deferred where task_id=r.id;
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
comment on table private.aios_task_reaper_quarantine is
  'Durable owner-review quarantine. Unresolved rows exclude tasks from stale-task reaper selection until an authenticated organization owner/admin resolves them.';
comment on function private.aios_reap_stale_tasks(interval) is
  'Per-mission-subtree and per-task isolated stale-task recovery. Transient lock conflicts defer; invariant failures quarantine; audit locks are acquired after all row-lock attempts using non-blocking try-locks.';
