-- NON-PRODUCTION ONLY (throwaway database built from supabase/migrations + proposal 001 applied). NEVER run against production:
-- if the guard were missing, this would take an ACCESS EXCLUSIVE lock and truncate the audit table (rolled back, but still unsafe).
begin;
do $$
declare failed boolean := false; msg text;
begin
  begin truncate public.aios_audit_events; exception when others then failed := true; msg := sqlerrm; end;
  if not failed then raise exception 'TRUNCATE on audit events was NOT blocked for the current role'; end if;
  if msg not ilike '%append-only%' then raise exception 'blocked for an unexpected reason: %', msg; end if;
  set local role service_role;
  failed := false;
  begin truncate public.aios_audit_events; exception when others then failed := true; end;
  if not failed then raise exception 'TRUNCATE on audit events was NOT blocked for service_role'; end if;
end $$;
rollback;
select 'ok: audit truncate guard (non-production)' as result;
