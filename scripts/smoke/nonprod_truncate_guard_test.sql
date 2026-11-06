-- NON-PRODUCTION ONLY (throwaway database built from supabase/migrations + proposal 001 applied). NEVER run against production.
-- Run: PGOPTIONS='-c smoke.nonprod=1' psql -X -f scripts/smoke/nonprod_truncate_guard_test.sql <throwaway DB>
-- Fences, in order: (1) psql must stop on the first error, so a failure can never be followed by a green "ok" line;
-- (2) the caller must explicitly assert smoke.nonprod=1; (3) the guard trigger must already be present and enabled BEFORE any
-- TRUNCATE is issued, so a missing guard aborts instead of truncating; (4) everything runs in one transaction that is rolled back.
\set ON_ERROR_STOP on
begin;
set local lock_timeout = '2s';
do $$
declare failed boolean; msg text;
begin
  if coalesce(current_setting('smoke.nonprod', true), '') <> '1' then
    raise exception 'refusing to run: set PGOPTIONS=-c smoke.nonprod=1 to confirm this is a throwaway database';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = to_regclass('public.aios_audit_events') and tgname = 'trg_aios_audit_no_truncate' and tgenabled in ('O', 'A') and (tgtype & 32) = 32) then
    raise exception 'refusing to run: the TRUNCATE guard trigger is not present and enabled (apply proposal 001 first)';
  end if;

  failed := false;
  begin truncate public.aios_audit_events; exception when others then failed := true; msg := sqlerrm; end;
  if not failed then raise exception 'TRUNCATE on audit events was NOT blocked for the current role'; end if;
  if msg not ilike '%append-only%' then raise exception 'blocked for an unexpected reason: %', msg; end if;

  set local role service_role;
  failed := false;
  begin truncate public.aios_audit_events; exception when others then failed := true; msg := sqlerrm; end;
  reset role;
  if not failed then raise exception 'TRUNCATE on audit events was NOT blocked for service_role'; end if;
end $$;
rollback;
select 'ok: audit truncate guard (non-production)' as result;
