-- READ-ONLY verification after proposal 001 is applied in an approved window. Expect every row PASS.
select check_id, status, detail from (
 select 'P1 service_role cannot TRUNCATE audit events' check_id,
   case when not has_table_privilege('service_role','public.aios_audit_events','TRUNCATE') then 'PASS' else 'FAIL' end status, 'privilege check' detail
 union all select 'P2 TRUNCATE guard trigger present and enabled',
   case when exists (select 1 from pg_trigger where tgrelid='public.aios_audit_events'::regclass and tgname='trg_aios_audit_no_truncate' and tgenabled='O' and (tgtype&32)=32) then 'PASS' else 'FAIL' end, 'trg_aios_audit_no_truncate'
 union all select 'P3 pre-existing audit UPDATE/DELETE guards still enabled',
   case when exists (select 1 from pg_trigger where tgrelid='public.aios_audit_events'::regclass and tgenabled='O' and (tgtype&1)=1 and (tgtype&2)=2 and (tgtype&16)=16)
         and exists (select 1 from pg_trigger where tgrelid='public.aios_audit_events'::regclass and tgenabled='O' and (tgtype&1)=1 and (tgtype&2)=2 and (tgtype&8)=8) then 'PASS' else 'FAIL' end, 'by trigger type'
 union all select 'P4 guard function not executable by clients',
   case when not has_function_privilege('anon','private.aios_audit_no_truncate()','execute') and not has_function_privilege('authenticated','private.aios_audit_no_truncate()','execute') and not has_function_privilege('service_role','private.aios_audit_no_truncate()','execute') then 'PASS' else 'FAIL' end, 'anon/authenticated/service_role'
 union all select 'P5 guard function SECURITY DEFINER with pinned path',
   case when exists (select 1 from pg_proc where oid='private.aios_audit_no_truncate()'::regprocedure and prosecdef and exists (select 1 from unnest(coalesce(proconfig,'{}')) c where c like 'search_path=%')) then 'PASS' else 'FAIL' end, 'private.aios_audit_no_truncate()'
) t order by 1;
-- Then re-run scripts/smoke/run_smoke.sh: S11 must now read PASS and no other row may have changed from the baseline.
