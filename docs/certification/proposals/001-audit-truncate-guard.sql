-- PROPOSAL 001 (NOT APPLIED; requires explicit owner approval). Forward-only. Touches no historical evidence, no existing trigger.
-- Gap: public.aios_audit_events has BEFORE UPDATE/DELETE row triggers but nothing stops TRUNCATE, and service_role holds TRUNCATE.
begin;
revoke truncate on public.aios_audit_events from service_role;

create or replace function private.aios_audit_no_truncate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin raise exception 'audit events are append-only: TRUNCATE is not permitted' using errcode = '42501'; end $$;
revoke all on function private.aios_audit_no_truncate() from public, anon, authenticated, service_role;

drop trigger if exists trg_aios_audit_no_truncate on public.aios_audit_events;
create trigger trg_aios_audit_no_truncate before truncate on public.aios_audit_events
  for each statement execute function private.aios_audit_no_truncate();
commit;

-- Post-deployment verification (read-only):
--   select has_table_privilege('service_role','public.aios_audit_events','TRUNCATE');          -- expect false
--   select tgenabled from pg_trigger where tgname='trg_aios_audit_no_truncate';                 -- expect 'O'
--   select tgname, tgenabled from pg_trigger where tgrelid='public.aios_audit_events'::regclass and not tgisinternal;  -- the 5 pre-existing triggers still 'O'
-- Rollback: drop trigger trg_aios_audit_no_truncate on public.aios_audit_events; drop function private.aios_audit_no_truncate(); grant truncate on public.aios_audit_events to service_role;
-- Failure modes: a maintenance job that truncates audit events will now fail (none found in repo migrations); the table owner (postgres) can still disable triggers - out of scope.
