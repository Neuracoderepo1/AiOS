-- AiOS production smoke test (READ-ONLY). One SELECT; no writes, no temp objects. Safe to paste into the Supabase SQL editor.
-- Output: check_id | status (PASS/FAIL/WARN/INFO) | detail.  FAIL = control broken. WARN = documented known gap. INFO = context only.
-- Run via scripts/smoke/run_smoke.sh (forces a read-only session, requires every row to be present, fails the run on any FAIL).
--
-- Settings (custom GUCs, set by run_smoke.sh through PGOPTIONS; defaults are the production behaviour):
--   smoke.profile               'production' (default) | 'replay'   -- replay = throwaway DB built from migrations; production-only
--                                                                       state (S20) is reported INFO instead of FAIL
--   smoke.proposal_001_applied  '0' (default) | '1'                 -- '1' = proposal 001 is expected to be live: S11 FAIL unless complete
-- Every object lookup uses to_regclass/to_regprocedure so a missing object is a FAIL row, never a query error that hides the rest.
with cfg as (
  select coalesce(nullif(current_setting('smoke.profile', true), ''), 'production') as profile,
         coalesce(nullif(current_setting('smoke.proposal_001_applied', true), ''), '0') as p001
), jobs as (
  select j.jobid, j.active, j.schedule,
         case when j.command ilike '%aios_expire_stale_approvals%' then 'expiry'
              when j.command ilike '%aios_reap_stale_tasks%' then 'reaper' end as kind
  from cron.job j
), audit as (select to_regclass('public.aios_audit_events') as oid)
select check_id, status, detail from (
 select 'S00 session is read-only' check_id,
        case when current_setting('transaction_read_only') = 'on' then 'PASS' else 'WARN' end status,
        'transaction_read_only='||current_setting('transaction_read_only')||' (run_smoke.sh refuses anything but PASS)' detail
 union all select 'S01 exactly one active expiry job and one active reaper job, every 5 min',
        case when (select count(*) from jobs where kind = 'expiry' and active and schedule = '*/5 * * * *') = 1
              and (select count(*) from jobs where kind = 'reaper' and active and schedule = '*/5 * * * *') = 1
              and (select count(*) from jobs where kind is not null and active) = 2 then 'PASS' else 'FAIL' end,
        coalesce((select string_agg('job '||jobid::text||' '||coalesce(kind,'other')||' '||schedule||' active='||active::text, '; ' order by jobid) from jobs), 'no cron jobs')
 union all select 'S02 cron liveness (each AiOS job succeeded in last 15 min)',
        case when exists (select 1 from jobs j join cron.job_run_details d on d.jobid = j.jobid where j.kind = 'expiry' and d.status = 'succeeded' and d.start_time > now() - interval '15 minutes')
              and exists (select 1 from jobs j join cron.job_run_details d on d.jobid = j.jobid where j.kind = 'reaper' and d.status = 'succeeded' and d.start_time > now() - interval '15 minutes') then 'PASS' else 'FAIL' end,
        'last success expiry='||coalesce((select max(d.start_time)::text from jobs j join cron.job_run_details d on d.jobid = j.jobid where j.kind = 'expiry' and d.status = 'succeeded'), 'never')
        ||' reaper='||coalesce((select max(d.start_time)::text from jobs j join cron.job_run_details d on d.jobid = j.jobid where j.kind = 'reaper' and d.status = 'succeeded'), 'never')
 union all select 'S03 cron failures last 60 min',
        case when (select count(*) from cron.job_run_details where status = 'failed' and start_time > now() - interval '60 minutes') = 0 then 'PASS' else 'FAIL' end,
        'failed='||(select count(*) from cron.job_run_details where status = 'failed' and start_time > now() - interval '60 minutes')::text
 union all select 'S04 cron history 24h (context)', 'INFO',
        coalesce((select string_agg(status||'='||c::text, ', ') from (select status, count(*) c from cron.job_run_details where start_time > now() - interval '24 hours' group by status) x), 'no runs')
 union all select 'S05 no stale pending approvals (lapsed >10 min, or no expiry and >24 h old, unless an owner-retain decision covers it)',
        case when (select count(*) from public.aios_approvals ap where ap.status = 'pending' and (
                     ap.expires_at < now() - interval '10 minutes'
                     or (ap.expires_at is null and ap.created_at < now() - interval '24 hours'
                         and not exists (select 1 from public.aios_backlog_effective_dispositions d where d.entity_type = 'approval' and d.entity_id = ap.id and d.disposition = 'owner_decision_retain')))) = 0
             then 'PASS' else 'FAIL' end,
        'lapsed_past_grace='||(select count(*) from public.aios_approvals where status = 'pending' and expires_at < now() - interval '10 minutes')::text
        ||' null_expiry_unretained='||(select count(*) from public.aios_approvals ap where ap.status = 'pending' and ap.expires_at is null and ap.created_at < now() - interval '24 hours'
              and not exists (select 1 from public.aios_backlog_effective_dispositions d where d.entity_type = 'approval' and d.entity_id = ap.id and d.disposition = 'owner_decision_retain'))::text
        ||' owner_retained_pending='||(select count(*) from public.aios_approvals ap where ap.status = 'pending'
              and exists (select 1 from public.aios_backlog_effective_dispositions d where d.entity_type = 'approval' and d.entity_id = ap.id and d.disposition = 'owner_decision_retain'))::text
 union all select 'S06 approval status counts (context)', 'INFO',
        coalesce((select string_agg(status||'='||c::text, ', ') from (select status, count(*) c from public.aios_approvals group by status) x), 'none')
 union all select 'S07 no disabled or replica-only triggers in public/private',
        case when not exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where not t.tgisinternal and t.tgenabled in ('D', 'R') and n.nspname in ('public', 'private')) then 'PASS' else 'FAIL' end,
        coalesce((select string_agg(c.relname||'.'||t.tgname||'='||t.tgenabled::text, ', ') from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where not t.tgisinternal and t.tgenabled in ('D', 'R') and n.nspname in ('public', 'private')), 'none disabled')
 union all select 'S08 approval integrity triggers enabled (6 expected)',
        case when (select count(*) from pg_trigger where tgrelid = to_regclass('public.aios_approvals') and tgenabled in ('O', 'A') and tgname in ('trg_aios_validate_approval_integrity', 'trg_validate_agent_org', 'trg_validate_task_org', 'trg_aios_approval_status_guard', 'trg_aios_log_approval_audit', 'trg_aios_approval_default_expiry')) = 6 then 'PASS' else 'FAIL' end,
        'enabled='||(select count(*) from pg_trigger where tgrelid = to_regclass('public.aios_approvals') and tgenabled in ('O', 'A') and tgname in ('trg_aios_validate_approval_integrity', 'trg_validate_agent_org', 'trg_validate_task_org', 'trg_aios_approval_status_guard', 'trg_aios_log_approval_audit', 'trg_aios_approval_default_expiry'))::text
 union all select 'S09 audit table blocks UPDATE (enabled BEFORE-row trigger)',
        case when exists (select 1 from pg_trigger, audit where tgrelid = audit.oid and tgenabled in ('O', 'A') and (tgtype & 1) = 1 and (tgtype & 2) = 2 and (tgtype & 4) = 0 and (tgtype & 16) = 16) then 'PASS' else 'FAIL' end, 'BEFORE ROW trigger on UPDATE only (not an INSERT-OR-UPDATE validator), name-independent'
 union all select 'S10 audit table blocks DELETE (enabled BEFORE-row trigger)',
        case when exists (select 1 from pg_trigger, audit where tgrelid = audit.oid and tgenabled in ('O', 'A') and (tgtype & 1) = 1 and (tgtype & 2) = 2 and (tgtype & 4) = 0 and (tgtype & 8) = 8) then 'PASS' else 'FAIL' end, 'BEFORE ROW trigger on DELETE, not combined with INSERT, name-independent'
 union all select 'S11 audit table blocks TRUNCATE (proposal 001)',
        case when (select p001 from cfg) = '1' then
               case when has_trunc_trigger and not svc_trunc then 'PASS' else 'FAIL' end
             when has_trunc_trigger and not svc_trunc then 'PASS'
             when has_trunc_trigger <> (not svc_trunc) then 'FAIL'   -- half applied is never acceptable
             else 'WARN' end,
        'service_role TRUNCATE='||svc_trunc::text||'; enabled BEFORE TRUNCATE trigger='||has_trunc_trigger::text||'; proposal_001_expected_live='||(select p001 from cfg)||' (WARN = known gap until proposal 001 is applied; FAIL if half-applied or expected live)'
   from (select coalesce(exists (select 1 from pg_trigger, audit where tgrelid = audit.oid and tgenabled in ('O', 'A') and (tgtype & 32) = 32 and (tgtype & 2) = 2), false) as has_trunc_trigger,
                coalesce(has_table_privilege('service_role', (select oid from audit), 'TRUNCATE'), true) as svc_trunc) s
 union all select 'S12 RLS enabled on all public/private tables',
        case when not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r', 'p') and n.nspname in ('public', 'private') and not c.relrowsecurity) then 'PASS' else 'FAIL' end,
        coalesce((select string_agg(n.nspname||'.'||c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r', 'p') and n.nspname in ('public', 'private') and not c.relrowsecurity), 'all tables have RLS')
 union all select 'S13 SECURITY DEFINER functions pin search_path',
        case when not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.prosecdef and n.nspname in ('public', 'private') and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')) then 'PASS' else 'FAIL' end,
        coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.prosecdef and n.nspname in ('public', 'private') and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')), 'all pinned')
 union all select 'S14 anon cannot execute SECURITY DEFINER functions',
        case when not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.prosecdef and n.nspname in ('public', 'private') and has_function_privilege('anon', p.oid, 'execute')) then 'PASS' else 'FAIL' end,
        coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.prosecdef and n.nspname in ('public', 'private') and has_function_privilege('anon', p.oid, 'execute')), 'none')
 union all select 'S15 no anon table privileges in public',
        case when not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pr(p) where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm') and has_table_privilege('anon', c.oid, pr.p)) then 'PASS' else 'FAIL' end,
        'checked SELECT/INSERT/UPDATE/DELETE/TRUNCATE on tables, partitioned tables, views, matviews'
 union all select 'S16 no client privileges on private tables',
        case when not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join (values ('anon'), ('authenticated')) r(role) cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pr(p) where n.nspname = 'private' and c.relkind in ('r', 'p') and has_table_privilege(r.role, c.oid, pr.p)) then 'PASS' else 'FAIL' end,
        'anon/authenticated x SELECT/INSERT/UPDATE/DELETE/TRUNCATE'
 union all select 'S17 authenticated has no write grants on approvals/audit/invocations',
        case when (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('aios_approvals', 'aios_audit_events', 'aios_tool_invocations')) = 3
              and not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) pr(p) where n.nspname = 'public' and c.relname in ('aios_approvals', 'aios_audit_events', 'aios_tool_invocations') and has_table_privilege('authenticated', c.oid, pr.p)) then 'PASS' else 'FAIL' end,
        'INSERT/UPDATE/DELETE/TRUNCATE (FAIL also if any of the three tables is missing)'
 union all select 'S18 expiry function is SECURITY DEFINER with pinned path',
        case when exists (select 1 from pg_proc where oid = to_regprocedure('private.aios_expire_stale_approvals()') and prosecdef and exists (select 1 from unnest(coalesce(proconfig, '{}')) c where c like 'search_path=%')) then 'PASS' else 'FAIL' end,
        'private.aios_expire_stale_approvals() present='||(to_regprocedure('private.aios_expire_stale_approvals()') is not null)::text
 union all select 'S19 backlog view is security_invoker',
        case when exists (select 1 from pg_class where oid = to_regclass('public.aios_backlog_effective_dispositions') and coalesce(reloptions, '{}') @> array['security_invoker=true']) then 'PASS' else 'FAIL' end,
        'public.aios_backlog_effective_dispositions present='||(to_regclass('public.aios_backlog_effective_dispositions') is not null)::text
 union all select 'S20 owner-decision retain record present (production profile only)',
        case when (select profile from cfg) <> 'production' then 'INFO'
             when exists (select 1 from public.aios_backlog_dispositions where disposition = 'owner_decision_retain') then 'PASS' else 'FAIL' end,
        'profile='||(select profile from cfg)||' retain='||(select count(*) from public.aios_backlog_dispositions where disposition = 'owner_decision_retain')::text
 union all select 'S21 migration history (context)', 'INFO',
        coalesce((select count(*)::text||' applied; latest '||coalesce(max(version), 'none') from supabase_migrations.schema_migrations), 'unavailable')
 union all select 'S22 leaked-password protection', 'WARN', 'Not queryable via SQL. Documented exception: disabled. Check Auth settings / security advisor manually.'
 union all select 'S23 private functions are not executable by PUBLIC/anon/authenticated (except the two RLS helpers)',
        case when not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'private' and p.proname not in ('aios_is_org_member', 'aios_is_org_admin')
               and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')
                    or has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))) then 'PASS' else 'FAIL' end,
        coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'private' and p.proname not in ('aios_is_org_member', 'aios_is_org_admin')
               and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')
                    or has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 'none')
) t order by 1;
