-- Extend the canonical cron inventory for the durable mission completion worker.
-- This keeps the Part E global verifier from classifying the newly registered worker as schedule drift.
create or replace function private.aios_schedule_check() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare v jsonb := '[]'::jsonb; e record; j record;
begin
  for e in select * from (values
      ('aios-restoration-watchdog', '*/5 * * * *', 'select private.aios_restoration_watchdog()'),
      ('aios-audit-verify-hourly',  '7 * * * *',   'select private.aios_scheduled_verify()'),
      ('aios-reap-stale-tasks',     '*/5 * * * *', null),
      ('aios-expire-stale-approvals','*/5 * * * *', null),
      ('aios-reconcile-mission-completions','* * * * *', 'select private.aios_process_mission_reconciliation_queue(100)')) as x(jobname, schedule, command) loop
    if (select count(*) from cron.job where jobname = e.jobname) > 1 then
      v := v || jsonb_build_object('kind', 'duplicate_job', 'job', e.jobname);   -- cron.job is keyed by (jobname, username): another user re-scheduling creates a twin
    end if;
    select * into j from cron.job where jobname = e.jobname order by jobid limit 1;
    if not found then v := v || jsonb_build_object('kind', 'job_missing', 'job', e.jobname);
    else
      if not j.active then v := v || jsonb_build_object('kind', 'job_inactive', 'job', e.jobname); end if;
      if j.schedule <> e.schedule then v := v || jsonb_build_object('kind', 'schedule_changed', 'job', e.jobname, 'actual', j.schedule); end if;
      if e.command is not null and btrim(j.command) <> e.command then v := v || jsonb_build_object('kind', 'command_changed', 'job', e.jobname); end if;
    end if;
  end loop;
  return jsonb_build_object('problem_count', jsonb_array_length(v), 'problems', v,
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object('job', jobname, 'schedule', schedule, 'active', active, 'username', username) order by jobname), '[]'::jsonb) from cron.job where jobname like 'aios-%'));
end $fn$;
revoke all on function private.aios_schedule_check() from public,anon,authenticated,service_role;
comment on function private.aios_schedule_check() is 'Fail-closed inventory of every required AiOS cron job, including durable mission reconciliation.';
