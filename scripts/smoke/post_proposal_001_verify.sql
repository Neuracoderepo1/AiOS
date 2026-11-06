-- READ-ONLY verification after proposal 001 is applied in an approved window. Expect every row PASS.
-- Run via: SMOKE_MODE=post001 scripts/smoke/run_smoke.sh  (requires all six rows; a missing object is a FAIL row, never a query error).
select check_id, status, detail from (
 select 'P1 service_role cannot TRUNCATE audit events' check_id,
   case when to_regclass('public.aios_audit_events') is not null and not has_table_privilege('service_role', to_regclass('public.aios_audit_events'), 'TRUNCATE') then 'PASS' else 'FAIL' end status, 'privilege check' detail
 union all select 'P2 TRUNCATE guard trigger present and enabled',
   case when exists (select 1 from pg_trigger where tgrelid = to_regclass('public.aios_audit_events') and tgname = 'trg_aios_audit_no_truncate' and tgenabled in ('O', 'A') and (tgtype & 32) = 32 and (tgtype & 2) = 2) then 'PASS' else 'FAIL' end, 'trg_aios_audit_no_truncate, BEFORE TRUNCATE'
 union all select 'P3 pre-existing audit UPDATE/DELETE guards still enabled',
   case when exists (select 1 from pg_trigger where tgrelid = to_regclass('public.aios_audit_events') and tgenabled in ('O', 'A') and (tgtype & 1) = 1 and (tgtype & 2) = 2 and (tgtype & 4) = 0 and (tgtype & 16) = 16)
         and exists (select 1 from pg_trigger where tgrelid = to_regclass('public.aios_audit_events') and tgenabled in ('O', 'A') and (tgtype & 1) = 1 and (tgtype & 2) = 2 and (tgtype & 4) = 0 and (tgtype & 8) = 8) then 'PASS' else 'FAIL' end, 'by trigger type'
 union all select 'P4 guard function not executable by clients or PUBLIC',
   case when to_regprocedure('private.aios_audit_no_truncate()') is not null
         and not has_function_privilege('anon', to_regprocedure('private.aios_audit_no_truncate()'), 'execute')
         and not has_function_privilege('authenticated', to_regprocedure('private.aios_audit_no_truncate()'), 'execute')
         and not has_function_privilege('service_role', to_regprocedure('private.aios_audit_no_truncate()'), 'execute')
         and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where p.oid = to_regprocedure('private.aios_audit_no_truncate()') and a.grantee = 0 and a.privilege_type = 'EXECUTE')
        then 'PASS' else 'FAIL' end, 'anon/authenticated/service_role/PUBLIC'
 union all select 'P5 guard function SECURITY DEFINER with pinned path',
   case when exists (select 1 from pg_proc where oid = to_regprocedure('private.aios_audit_no_truncate()') and prosecdef and exists (select 1 from unnest(coalesce(proconfig, '{}')) c where c like 'search_path=%')) then 'PASS' else 'FAIL' end, 'private.aios_audit_no_truncate()'
 union all select 'P6 no other trigger on audit events was disabled',
   case when not exists (select 1 from pg_trigger where tgrelid = to_regclass('public.aios_audit_events') and not tgisinternal and tgenabled in ('D', 'R')) then 'PASS' else 'FAIL' end, 'no disabled or replica-only triggers'
) t order by 1;
-- Then re-run: SMOKE_PROPOSAL_001_APPLIED=1 scripts/smoke/run_smoke.sh   (S11 must PASS and no other row may change from the baseline).
