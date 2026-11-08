-- ET27 follow-up / DELETE protection for the invocation ledger.
--
-- Finding (static review of candidate e0a8c5d): `anon` and `authenticated` already have no DELETE privilege and there is no
-- DELETE RLS policy, but (a) `service_role` kept the default DELETE privilege and (b) nothing blocked row deletion by the table
-- owner. The only remaining barrier was the deferred audit FK, which protects an invocation only while an audit row references it;
-- an invocation with no audit row could be deleted.
--
-- This migration makes the invocation ledger append-only with respect to row deletion, mirroring the audit ledger:
--   1. DELETE is revoked from PUBLIC, anon, authenticated and service_role (privilege layer).
--   2. A BEFORE DELETE row trigger refuses every delete, including by the table owner (trigger layer).
-- No legitimate internal writer deletes invocation rows (no function, edge function, cron job or script does), and organization
-- deletion is already impossible because the cascade reaches the append-only audit ledger. The audit FK is left unchanged as a third
-- layer for audited rows.
--
-- Residual (documented, not claimed closed): the table owner or a superuser can still disable the trigger or ALTER the grants. That
-- is true of every trigger-based guard in this schema (audit ledger, seal guard) and needs an out-of-database control.
begin;

create or replace function private.aios_invocation_no_delete() returns trigger
language plpgsql security definer set search_path = '' as $f$
begin
  raise exception 'invocation ledger is append-only: DELETE refused' using errcode = '55000';
end $f$;
revoke all on function private.aios_invocation_no_delete() from public, anon, authenticated, service_role;

revoke delete on public.aios_tool_invocations from public, anon, authenticated, service_role;

drop trigger if exists trg_aios_invocation_no_delete on public.aios_tool_invocations;
create trigger trg_aios_invocation_no_delete before delete on public.aios_tool_invocations
  for each row execute function private.aios_invocation_no_delete();

commit;
