-- AiOS F-2 follow-up: approval row-count invariant and fail-closed persistence.
-- This migration patches the installed core function body only after asserting every
-- expected source fragment is present. It adds no hosted-side operational action.
begin;

create table if not exists private.aios_task_reaper_halt (
  id bigint generated always as identity primary key,
  organization_id uuid not null,
  task_id uuid,
  halted_at timestamptz not null default clock_timestamp(),
  sqlstate text,
  error text,
  cleared_at timestamptz,
  cleared_by uuid references auth.users(id),
  clear_note text,
  check ((cleared_at is null and cleared_by is null and clear_note is null)
      or (cleared_at is not null and cleared_by is not null and clear_note is not null))
);
alter table private.aios_task_reaper_halt enable row level security;
revoke all on private.aios_task_reaper_halt from public, anon, authenticated, service_role;
create unique index if not exists aios_task_reaper_halt_one_active
  on private.aios_task_reaper_halt ((true)) where cleared_at is null;

create or replace function private.aios_reaper_record_quarantine(
  p_task_id uuid, p_org_id uuid, p_reason text, p_sqlstate text, p_rationale text
) returns jsonb
language plpgsql security definer set search_path = ''
as $helper$
begin
  begin
    insert into private.aios_task_reaper_quarantine
      (task_id,organization_id,reason,sqlstate)
    values (p_task_id,p_org_id,p_reason,p_sqlstate)
    on conflict(task_id) do update set
      organization_id=excluded.organization_id,reason=excluded.reason,
      sqlstate=excluded.sqlstate,created_at=clock_timestamp(),
      resolved_at=null,resolved_by=null,resolution_note=null;
    delete from private.aios_task_reaper_deferred where task_id=p_task_id;
  exception when others then
    return jsonb_build_object('status','quarantine_unwritable',
      'sqlstate',sqlstate,'error',left(sqlerrm,500));
  end;

  begin
    insert into public.aios_backlog_dispositions
      (organization_id,entity_type,entity_id,classification,disposition,rationale,decided_by)
    values (p_org_id,'task',p_task_id,'needs_owner_review','manual_review',
      p_rationale,'job:aios_reap_stale_tasks')
    on conflict do nothing;
  exception when others then
    return jsonb_build_object('status','disposition_unwritten',
      'sqlstate',sqlstate,'error',left(sqlerrm,500));
  end;

  return jsonb_build_object('status','ok');
end
$helper$;
revoke all on function private.aios_reaper_record_quarantine(uuid,uuid,text,text,text)
  from public, anon, authenticated, service_role;

do $patch$
declare
  v_src text;
  v_next text;
  v_old text;
  v_new text;
begin
  select p.prosrc into v_src
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private' and p.proname='aios_reap_stale_tasks'
    and p.pronargs=1 and p.proargtypes[0]='interval'::regtype;
  if v_src is null then
    raise exception 'expected private.aios_reap_stale_tasks(interval) is missing';
  end if;

  -- Extend declarations without changing the existing function security boundary.
  v_old := '  v_org_id uuid;';
  v_new := '  v_org_id uuid;
  v_rows integer;
  v_q jsonb;
  v_disp_unwritten integer := 0;
  v_fail_closed jsonb;
  v_orig_state text;
  v_orig_err text;';
  if position(v_old in v_src)=0 then raise exception 'declaration anchor missing'; end if;
  v_next := replace(v_src,v_old,v_new);
  if v_next=v_src then raise exception 'declaration patch did not apply'; end if;
  v_src := v_next;

  -- Phase 1 deferred persistence: convert a queue-write failure into a durable
  -- owner-review quarantine; inability to persist that quarantine is fail-closed.
  v_old := '    insert into private.aios_task_reaper_deferred(task_id,attempts,next_attempt_at,last_sqlstate,last_error,updated_at)
    values (r.task_id,1,clock_timestamp()+interval ''2 seconds'',
      r.diagnostic->>''sqlstate'',r.diagnostic->>''error'',clock_timestamp())
    on conflict(task_id) do update set
      attempts=private.aios_task_reaper_deferred.attempts+1,
      next_attempt_at=clock_timestamp()+make_interval(secs=>least(300,power(2,least(private.aios_task_reaper_deferred.attempts+1,8))::integer)),
      last_sqlstate=excluded.last_sqlstate,last_error=excluded.last_error,updated_at=clock_timestamp();
    v_deferred := v_deferred+1;';
  v_new := '    begin
      insert into private.aios_task_reaper_deferred(task_id,attempts,next_attempt_at,last_sqlstate,last_error,updated_at)
      values (r.task_id,1,clock_timestamp()+interval ''2 seconds'',
        r.diagnostic->>''sqlstate'',r.diagnostic->>''error'',clock_timestamp())
      on conflict(task_id) do update set
        attempts=private.aios_task_reaper_deferred.attempts+1,
        next_attempt_at=clock_timestamp()+make_interval(secs=>least(300,power(2,least(private.aios_task_reaper_deferred.attempts+1,8))::integer)),
        last_sqlstate=excluded.last_sqlstate,last_error=excluded.last_error,updated_at=clock_timestamp();
      v_deferred := v_deferred+1;
    exception when others then
      v_q := private.aios_reaper_record_quarantine(r.task_id,
        (select t.organization_id from public.aios_tasks t where t.id=r.task_id),
        ''deferred_retry_persistence_failure'',sqlstate,
        ''Transient lock retry state could not be persisted; task requires owner review. ''||left(sqlerrm,500));
      if v_q->>''status''=''quarantine_unwritable'' then
        v_fail_closed := v_q||jsonb_build_object(''task_id'',r.task_id,
          ''organization_id'',(select t.organization_id from public.aios_tasks t where t.id=r.task_id));
        exit;
      end if;
      if v_q->>''status''=''disposition_unwritten'' then v_disp_unwritten:=v_disp_unwritten+1; end if;
      v_quarantined:=v_quarantined+1;
    end;';
  if position(v_old in v_src)=0 then raise exception 'phase-one deferred persistence anchor missing'; end if;
  v_src := replace(v_src,v_old,v_new);
  if position('v_fail_closed' in v_src)=0 then raise exception 'phase-one deferred patch failed'; end if;

  -- Do not enter public transition processing after a fail-closed Phase 1 failure.
  v_old := '  -- Phase 1 dispositions are persisted only after all row locks have been attempted.';
  v_new := '  if v_fail_closed is not null then
    return jsonb_build_object(''failed'',v_failed,''blocked_pending_approval'',v_blocked,
      ''skipped_needs_operator'',v_skipped,''deferred'',v_deferred,''quarantined'',v_quarantined,
      ''disposition_unwritten'',v_disp_unwritten,
      ''outcome'',''fail_closed_quarantine_unwritable'',''fail_closed'',v_fail_closed,
      ''max_age'',p_max_age::text);
  end if;

  -- Phase 1 dispositions are persisted only after all row locks have been attempted.';
  if position(v_old in v_src)=0 then raise exception 'phase-one boundary anchor missing'; end if;
  v_src := replace(v_src,v_old,v_new);

  -- Structural lock failures use the same isolated persistence path.
  v_old := '    insert into private.aios_task_reaper_quarantine(task_id,organization_id,reason,sqlstate)
    values (v_task_id,v_org_id,''Structural failure acquiring stale-task mission/task lock subtree'',null)
    on conflict(task_id) do update set organization_id=excluded.organization_id,reason=excluded.reason,
      sqlstate=excluded.sqlstate,created_at=clock_timestamp(),resolved_at=null,resolved_by=null,resolution_note=null;
    delete from private.aios_task_reaper_deferred where task_id=v_task_id;
    insert into public.aios_backlog_dispositions
      (organization_id,entity_type,entity_id,classification,disposition,rationale,decided_by)
    values (v_org_id,''task'',v_task_id,''needs_owner_review'',''manual_review'',
      ''Stale-task reaper could not safely acquire the task or mission lock subtree; task left unchanged for owner review.'',
      ''job:aios_reap_stale_tasks'')
    on conflict do nothing;
    v_quarantined := v_quarantined+1;';
  v_new := '    v_q := private.aios_reaper_record_quarantine(v_task_id,v_org_id,
      ''Structural failure acquiring stale-task mission/task lock subtree'',null,
      ''Stale-task reaper could not safely acquire the task or mission lock subtree; task left unchanged for owner review.'');
    if v_q->>''status''=''quarantine_unwritable'' then
      v_fail_closed := v_q||jsonb_build_object(''task_id'',v_task_id,''organization_id'',v_org_id);
      exit;
    end if;
    if v_q->>''status''=''disposition_unwritten'' then v_disp_unwritten:=v_disp_unwritten+1; end if;
    v_quarantined := v_quarantined+1;';
  if position(v_old in v_src)=0 then raise exception 'phase-one structural quarantine anchor missing'; end if;
  v_src := replace(v_src,v_old,v_new);

  -- Ensure Phase 1 structural persistence failure stops the run before Phase 2.
  v_old := '  -- PHASE 2: each task transition is an independent subtransaction.';
  v_new := '  if v_fail_closed is not null then
    return jsonb_build_object(''failed'',v_failed,''blocked_pending_approval'',v_blocked,
      ''skipped_needs_operator'',v_skipped,''deferred'',v_deferred,''quarantined'',v_quarantined,
      ''disposition_unwritten'',v_disp_unwritten,
      ''outcome'',''fail_closed_quarantine_unwritable'',''fail_closed'',v_fail_closed,
      ''max_age'',p_max_age::text);
  end if;

  -- PHASE 2: each task transition is an independent subtransaction.';
  if position(v_old in v_src)=0 then raise exception 'phase-two boundary anchor missing'; end if;
  v_src := replace(v_src,v_old,v_new);

  -- Approval transition must verify exactly one task row before touching its mission.
  v_old := '        update public.aios_tasks set status=''blocked_pending_approval''
          where id=r.id and status=''running'';
        if r.mission_id is not null then
          update public.aios_missions set status=''blocked_pending_approval''
          where id=r.mission_id and status=''running'';
        end if;
        v_blocked:=v_blocked+1;
        v_outcome:=''blocked'';';
  v_new := '        update public.aios_tasks set status=''blocked_pending_approval''
          where id=r.id and status=''running'';
        get diagnostics v_rows = row_count;
        if v_rows=1 then
          if r.mission_id is not null then
            update public.aios_missions set status=''blocked_pending_approval''
            where id=r.mission_id and status=''running'';
          end if;
          v_blocked:=v_blocked+1;
          v_outcome:=''blocked'';
        else
          v_q := private.aios_reaper_record_quarantine(r.id,r.organization_id,
            ''approval_block_rowcount_invariant'',''P0002'',
            ''Stale-task approval-block UPDATE matched no row; task and mission remain unchanged and require owner review.'');
          if v_q->>''status''=''quarantine_unwritable'' then
            v_fail_closed := v_q||jsonb_build_object(''task_id'',r.id,''organization_id'',r.organization_id);
            exit;
          end if;
          if v_q->>''status''=''disposition_unwritten'' then v_disp_unwritten:=v_disp_unwritten+1; end if;
          v_quarantined:=v_quarantined+1;
          v_outcome:=''quarantined'';
        end if;';
  if position(v_old in v_src)=0 then raise exception 'approval branch anchor missing'; end if;
  v_src := replace(v_src,v_old,v_new);

  -- Failed-transition row-count failure also uses isolated persistence.
  v_old := '          insert into private.aios_task_reaper_quarantine(task_id,organization_id,reason,sqlstate)
          values (r.id,r.organization_id,
            ''Stale-task recovery UPDATE matched no row; task was not transitioned'', ''P0002'')
          on conflict(task_id) do update set organization_id=excluded.organization_id,
            reason=excluded.reason,sqlstate=excluded.sqlstate,created_at=clock_timestamp(),
            resolved_at=null,resolved_by=null,resolution_note=null;
          delete from private.aios_task_reaper_deferred where task_id=r.id;
          insert into public.aios_backlog_dispositions
            (organization_id,entity_type,entity_id,classification,disposition,rationale,decided_by)
          values (r.organization_id,''task'',r.id,''needs_owner_review'',''manual_review'',
            ''Stale-task recovery UPDATE matched no row; task remains unchanged and requires owner review.'',
            ''job:aios_reap_stale_tasks'')
          on conflict do nothing;
          v_quarantined:=v_quarantined+1;
          v_outcome:=''quarantined'';';
  v_new := '          v_q := private.aios_reaper_record_quarantine(r.id,r.organization_id,
            ''Stale-task recovery UPDATE matched no row; task was not transitioned'',''P0002'',
            ''Stale-task recovery UPDATE matched no row; task remains unchanged and requires owner review.'');
          if v_q->>''status''=''quarantine_unwritable'' then
            v_fail_closed := v_q||jsonb_build_object(''task_id'',r.id,''organization_id'',r.organization_id);
            exit;
          end if;
          if v_q->>''status''=''disposition_unwritten'' then v_disp_unwritten:=v_disp_unwritten+1; end if;
          v_quarantined:=v_quarantined+1;
          v_outcome:=''quarantined'';';
  if position(v_old in v_src)=0 then raise exception 'failed transition quarantine anchor missing'; end if;
  v_src := replace(v_src,v_old,v_new);

  -- Non-lock exception handling preserves original diagnostics and never lets
  -- quarantine/disposition write errors escape the record savepoint.
  v_old := '        insert into private.aios_task_reaper_quarantine(task_id,organization_id,reason,sqlstate)
        values (r.id,r.organization_id,''Stale-task transition invariant failure: ''||left(sqlerrm,500),sqlstate)
        on conflict(task_id) do update set organization_id=excluded.organization_id,reason=excluded.reason,
          sqlstate=excluded.sqlstate,created_at=clock_timestamp(),resolved_at=null,resolved_by=null,resolution_note=null;
        delete from private.aios_task_reaper_deferred where task_id=r.id;
        insert into public.aios_backlog_dispositions
          (organization_id,entity_type,entity_id,classification,disposition,rationale,decided_by)
        values (r.organization_id,''task'',r.id,''needs_owner_review'',''manual_review'',
          ''Stale-task recovery failed safely with SQLSTATE ''||sqlstate||''; task transition rolled back and requires owner review. ''||left(sqlerrm,500),
          ''job:aios_reap_stale_tasks'')
        on conflict do nothing;
        v_quarantined:=v_quarantined+1;';
  v_new := '        v_orig_state := sqlstate;
        v_orig_err := sqlerrm;
        v_q := private.aios_reaper_record_quarantine(r.id,r.organization_id,
          ''Stale-task transition invariant failure: ''||left(v_orig_err,500),v_orig_state,
          ''Stale-task recovery failed safely with SQLSTATE ''||v_orig_state||
          ''; task transition rolled back and requires owner review. ''||left(v_orig_err,500));
        if v_q->>''status''=''quarantine_unwritable'' then
          v_fail_closed := v_q||jsonb_build_object(''task_id'',r.id,
            ''organization_id'',r.organization_id,''original_sqlstate'',v_orig_state,
            ''original_error'',left(v_orig_err,500));
          exit;
        end if;
        if v_q->>''status''=''disposition_unwritten'' then v_disp_unwritten:=v_disp_unwritten+1; end if;
        v_quarantined:=v_quarantined+1;';
  if position(v_old in v_src)=0 then raise exception 'exception quarantine anchor missing'; end if;
  v_src := replace(v_src,v_old,v_new);

  -- Do not continue to later records after a quarantine persistence failure.
  v_old := '    end;
  end loop;

  return jsonb_build_object(''failed'',v_failed,''blocked_pending_approval'',v_blocked,
    ''skipped_needs_operator'',v_skipped,''deferred'',v_deferred,''quarantined'',v_quarantined,
    ''max_age'',p_max_age::text);';
  v_new := '    end;
    if v_fail_closed is not null then exit; end if;
  end loop;

  return jsonb_build_object(''failed'',v_failed,''blocked_pending_approval'',v_blocked,
    ''skipped_needs_operator'',v_skipped,''deferred'',v_deferred,''quarantined'',v_quarantined,
    ''disposition_unwritten'',v_disp_unwritten,
    ''outcome'',case when v_fail_closed is null then ''ok'' else ''fail_closed_quarantine_unwritable'' end,
    ''fail_closed'',v_fail_closed,
    ''max_age'',p_max_age::text);';
  if position(v_old in v_src)=0 then raise exception 'phase-two loop return anchor missing'; end if;
  v_src := replace(v_src,v_old,v_new);

  execute format(
    'create or replace function private.aios_reap_stale_tasks(p_max_age interval default %L) returns jsonb language plpgsql security definer set search_path = '''' as %L',
    '00:10:00'::interval, v_src
  );
end
$patch$;

create or replace function private.aios_reap_stale_tasks_scheduled(p_max_age interval)
returns jsonb
language plpgsql security definer set search_path = ''
as $scheduled$
declare
  v_result jsonb;
  v_fail jsonb;
begin
  if not pg_catalog.pg_try_advisory_xact_lock(
    pg_catalog.hashtextextended('aios.task_reaper.scheduled',0)
  ) then
    return jsonb_build_object('outcome','busy');
  end if;

  if exists (select 1 from private.aios_task_reaper_halt h where h.cleared_at is null) then
    return jsonb_build_object('outcome','halted');
  end if;

  v_result := private.aios_reap_stale_tasks(p_max_age);
  if v_result->>'outcome'='fail_closed_quarantine_unwritable' then
    v_fail := v_result->'fail_closed';
    insert into private.aios_task_reaper_halt(organization_id,task_id,sqlstate,error)
    values ((v_fail->>'organization_id')::uuid,(v_fail->>'task_id')::uuid,
      v_fail->>'sqlstate',coalesce(v_fail->>'error',v_fail->>'original_error','quarantine persistence failed'));
    return v_result||jsonb_build_object('outcome','halted_fail_closed');
  end if;
  return v_result;
end
$scheduled$;
revoke all on function private.aios_reap_stale_tasks_scheduled(interval)
  from public, anon, authenticated, service_role;
revoke all on function private.aios_reap_stale_tasks(interval)
  from public, anon, authenticated, service_role;
revoke all on function private.aios_reaper_record_quarantine(uuid,uuid,text,text,text)
  from public, anon, authenticated, service_role;

select cron.schedule(
  'aios-reap-stale-tasks',
  '*/5 * * * *',
  $cron$select private.aios_reap_stale_tasks_scheduled('10 minutes'::interval)$cron$
);

-- Keep the canonical schedule verifier pinned to the exact command text.
create or replace function private.aios_schedule_check() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare v jsonb := '[]'::jsonb; e record; j record;
begin
  for e in select * from (values
      ('aios-restoration-watchdog', '*/5 * * * *', 'select private.aios_restoration_watchdog()'),
      ('aios-audit-verify-hourly',  '7 * * * *',   'select private.aios_scheduled_verify()'),
      ('aios-reap-stale-tasks',     '*/5 * * * *', 'select private.aios_reap_stale_tasks_scheduled(''10 minutes''::interval)'),
      ('aios-expire-stale-approvals','*/5 * * * *', null),
      ('aios-reconcile-mission-completions','* * * * *', 'select private.aios_process_mission_reconciliation_queue(100)')) as x(jobname, schedule, command) loop
    if (select count(*) from cron.job where jobname = e.jobname) > 1 then
      v := v || jsonb_build_object('kind', 'duplicate_job', 'job', e.jobname);
    end if;
    select * into j from cron.job where jobname = e.jobname order by jobid limit 1;
    if not found then v := v || jsonb_build_object('kind', 'job_missing', 'job', e.jobname);
    else
      if not j.active then v := v || jsonb_build_object('kind', 'job_inactive', 'job', e.jobname); end if;
      if j.schedule <> e.schedule then v := v || jsonb_build_object('kind', 'schedule_changed', 'job', e.jobname, 'actual', j.schedule); end if;
      if e.command is not null and btrim(j.command) <> e.command then
        v := v || jsonb_build_object('kind', 'command_changed', 'job', e.jobname, 'actual', j.command);
      end if;
    end if;
  end loop;
  return jsonb_build_object('problem_count', jsonb_array_length(v), 'problems', v,
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object('job', jobname, 'schedule', schedule, 'active', active, 'username', username) order by jobname), '[]'::jsonb) from cron.job where jobname like 'aios-%'));
end
$fn$;
revoke all on function private.aios_schedule_check() from public, anon, authenticated, service_role;

-- Owner/admin halt clearance mirrors the existing task-quarantine RPC's
-- auth.uid() + membership-row lock authorization boundary.
create or replace function public.aios_clear_task_reaper_halt(p_resolution_note text)
returns jsonb
language plpgsql security definer set search_path = ''
as $clear$
declare
  v_actor uuid := auth.uid();
  v_org uuid;
  v_halt_id bigint;
  v_role text;
  v_rows integer;
begin
  if v_actor is null then raise exception 'authenticated owner identity required' using errcode='42501'; end if;
  if p_resolution_note is null or length(btrim(p_resolution_note))<12 then
    raise exception 'resolution note must contain at least 12 characters' using errcode='22023';
  end if;
  select h.organization_id into v_org
  from private.aios_task_reaper_halt h where h.cleared_at is null;
  if not found then raise exception 'active reaper halt not found' using errcode='P0002'; end if;
  -- Match the existing owner-resolution linearization order: membership first,
  -- then the protected halt row.
  select m.role::text into v_role
  from public.aios_organization_members m
  where m.organization_id=v_org and m.user_id=v_actor
  for update;
  if not found or v_role not in ('owner','admin','administrator') then
    raise exception 'organization owner/admin authorization required' using errcode='42501';
  end if;
  select h.id into v_halt_id
  from private.aios_task_reaper_halt h
  where h.cleared_at is null and h.organization_id=v_org
  for update;
  if not found then raise exception 'active reaper halt changed concurrently' using errcode='40001'; end if;
  update private.aios_task_reaper_halt
  set cleared_at=clock_timestamp(),cleared_by=v_actor,clear_note=btrim(p_resolution_note)
  where id=v_halt_id and cleared_at is null;
  get diagnostics v_rows=row_count;
  if v_rows<>1 then raise exception 'reaper halt changed concurrently' using errcode='40001'; end if;
  insert into public.aios_backlog_dispositions
    (organization_id,entity_type,entity_id,classification,disposition,rationale,decided_by)
  values (v_org,'task',coalesce(
    (select h.task_id from private.aios_task_reaper_halt h where h.id=v_halt_id),
    '00000000-0000-0000-0000-000000000000'::uuid),
    'owner_decision','owner_decision_retain',
    'Authorized owner/admin cleared the stale-task reaper halt. '||btrim(p_resolution_note),
    'owner:'||v_actor::text);
  return jsonb_build_object('halt_id',v_halt_id,'halt_cleared',true,'cleared_by',v_actor);
end
$clear$;
revoke all on function public.aios_clear_task_reaper_halt(text) from public, anon, service_role;
grant execute on function public.aios_clear_task_reaper_halt(text) to authenticated;

-- The cron owner is the migration role (normally postgres). Application roles
-- cannot call the private scheduled entry point directly.
comment on function private.aios_reap_stale_tasks_scheduled(interval) is
  'Serialized pg_cron entry point. Stops on a durable fail-closed halt until an organization owner/admin clears it.';
comment on table private.aios_task_reaper_halt is
  'Durable global stale-task reaper halt. Only an authenticated owner/admin of the affected organization may clear it.';

commit;
