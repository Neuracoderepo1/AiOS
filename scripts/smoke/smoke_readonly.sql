-- AiOS production smoke test (READ-ONLY). One SELECT; no writes, no temp objects. Safe to paste into the Supabase SQL editor.
-- Output: check_id | status (PASS/FAIL/WARN/INFO) | detail.  FAIL = control broken. WARN = documented known gap. INFO = context only.
-- Run via scripts/smoke/run_smoke.sh (forces default_transaction_read_only=on and fails the run on any FAIL).
select check_id, status, detail from (
 select 'S01 cron expiry job active every 5 min' check_id,
        case when exists (select 1 from cron.job where active and schedule = '*/5 * * * *' and command ilike '%aios_expire_stale_approvals%') then 'PASS' else 'FAIL' end status,
        coalesce((select string_agg('job '||jobid::text||' '||schedule||' active='||active::text, '; ') from cron.job), 'no cron jobs') detail
 union all select 'S02 cron liveness (success in last 15 min)',
        case when exists (select 1 from cron.job_run_details where status='succeeded' and start_time > now()-interval '15 minutes') then 'PASS' else 'FAIL' end,
        'last run: '||coalesce((select max(start_time)::text from cron.job_run_details),'never')
 union all select 'S03 cron failures last 60 min',
        case when (select count(*) from cron.job_run_details where status='failed' and start_time > now()-interval '60 minutes')=0 then 'PASS' else 'FAIL' end,
        'failed='||(select count(*) from cron.job_run_details where status='failed' and start_time > now()-interval '60 minutes')::text
 union all select 'S04 cron history 24h (context)', 'INFO',
        coalesce((select string_agg(status||'='||c::text, ', ') from (select status, count(*) c from cron.job_run_details where start_time > now()-interval '24 hours' group by status) x),'no runs')
 union all select 'S05 no pending approvals past expiry',
        case when (select count(*) from public.aios_approvals where status='pending' and expires_at < now())=0 then 'PASS' else 'FAIL' end,
        'stale_pending='||(select count(*) from public.aios_approvals where status='pending' and expires_at < now())::text
 union all select 'S06 approval status counts (context)', 'INFO',
        coalesce((select string_agg(status||'='||c::text, ', ') from (select status, count(*) c from public.aios_approvals group by status) x),'none')
 union all select 'S07 no disabled triggers in public/private',
        case when not exists (select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and t.tgenabled='D' and n.nspname in ('public','private')) then 'PASS' else 'FAIL' end,
        coalesce((select string_agg(c.relname||'.'||t.tgname, ', ') from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and t.tgenabled='D' and n.nspname in ('public','private')),'none disabled')
 union all select 'S08 approval integrity triggers enabled (5 expected)',
        case when (select count(*) from pg_trigger where tgrelid='public.aios_approvals'::regclass and tgenabled='O' and tgname in ('trg_aios_validate_approval_integrity','trg_validate_agent_org','trg_validate_task_org','trg_aios_approval_status_guard','trg_aios_log_approval_audit'))=5 then 'PASS' else 'FAIL' end,
        'enabled='||(select count(*) from pg_trigger where tgrelid='public.aios_approvals'::regclass and tgenabled='O' and tgname in ('trg_aios_validate_approval_integrity','trg_validate_agent_org','trg_validate_task_org','trg_aios_approval_status_guard','trg_aios_log_approval_audit'))::text
 union all select 'S09 audit table blocks UPDATE (enabled BEFORE-row trigger)',
        case when exists (select 1 from pg_trigger where tgrelid='public.aios_audit_events'::regclass and tgenabled='O' and (tgtype&1)=1 and (tgtype&2)=2 and (tgtype&16)=16) then 'PASS' else 'FAIL' end, 'by trigger type, name-independent'
 union all select 'S10 audit table blocks DELETE (enabled BEFORE-row trigger)',
        case when exists (select 1 from pg_trigger where tgrelid='public.aios_audit_events'::regclass and tgenabled='O' and (tgtype&1)=1 and (tgtype&2)=2 and (tgtype&8)=8) then 'PASS' else 'FAIL' end, 'by trigger type, name-independent'
 union all select 'S11 audit table blocks TRUNCATE (proposal 001)',
        case when exists (select 1 from pg_trigger where tgrelid='public.aios_audit_events'::regclass and tgenabled='O' and (tgtype&32)=32) and not has_table_privilege('service_role','public.aios_audit_events','TRUNCATE') then 'PASS' else 'WARN' end,
        'service_role TRUNCATE='||has_table_privilege('service_role','public.aios_audit_events','TRUNCATE')::text||'; truncate trigger='||exists (select 1 from pg_trigger where tgrelid='public.aios_audit_events'::regclass and (tgtype&32)=32)::text||' (WARN = known gap until proposal 001 is applied)'
 union all select 'S12 RLS enabled on all public/private tables',
        case when not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('r','p') and n.nspname in ('public','private') and not c.relrowsecurity) then 'PASS' else 'FAIL' end,
        coalesce((select string_agg(n.nspname||'.'||c.relname, ', ') from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('r','p') and n.nspname in ('public','private') and not c.relrowsecurity),'all tables have RLS')
 union all select 'S13 SECURITY DEFINER functions pin search_path',
        case when not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')) then 'PASS' else 'FAIL' end,
        coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')),'all pinned')
 union all select 'S14 anon cannot execute SECURITY DEFINER functions',
        case when not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and has_function_privilege('anon', p.oid, 'execute')) then 'PASS' else 'FAIL' end,
        coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and has_function_privilege('anon', p.oid, 'execute')),'none')
 union all select 'S15 no anon table privileges in public',
        case when not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE')) pr(p) where n.nspname='public' and c.relkind in ('r','p','v') and has_table_privilege('anon', c.oid, pr.p)) then 'PASS' else 'FAIL' end, 'checked SELECT/INSERT/UPDATE/DELETE'
 union all select 'S16 no client privileges on private tables',
        case when not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace cross join (values ('anon'),('authenticated')) r(role) cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE')) pr(p) where n.nspname='private' and c.relkind in ('r','p') and has_table_privilege(r.role, c.oid, pr.p)) then 'PASS' else 'FAIL' end, 'anon/authenticated'
 union all select 'S17 authenticated has no write grants on approvals/audit/invocations',
        case when not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace cross join (values ('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE')) pr(p) where n.nspname='public' and c.relname in ('aios_approvals','aios_audit_events','aios_tool_invocations') and has_table_privilege('authenticated', c.oid, pr.p)) then 'PASS' else 'FAIL' end, 'INSERT/UPDATE/DELETE/TRUNCATE'
 union all select 'S18 expiry function is SECURITY DEFINER with pinned path',
        case when exists (select 1 from pg_proc where oid='private.aios_expire_stale_approvals()'::regprocedure and prosecdef and exists (select 1 from unnest(coalesce(proconfig,'{}')) c where c like 'search_path=%')) then 'PASS' else 'FAIL' end, 'private.aios_expire_stale_approvals()'
 union all select 'S19 backlog view is security_invoker',
        case when exists (select 1 from pg_class where oid='public.aios_backlog_effective_dispositions'::regclass and coalesce(reloptions,'{}') @> array['security_invoker=true']) then 'PASS' else 'FAIL' end, 'public.aios_backlog_effective_dispositions'
 union all select 'S20 owner-decision retain record present',
        case when exists (select 1 from public.aios_backlog_dispositions where disposition='owner_decision_retain') then 'PASS' else 'FAIL' end,
        'retain='||(select count(*) from public.aios_backlog_dispositions where disposition='owner_decision_retain')::text
 union all select 'S21 migration history (context)', 'INFO',
        (select count(*)::text||' applied; latest '||max(version) from supabase_migrations.schema_migrations)
 union all select 'S22 leaked-password protection', 'WARN', 'Not queryable via SQL. Documented exception: disabled. Check Auth settings / security advisor manually.'
) t order by 1;
