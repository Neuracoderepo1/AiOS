-- ET27 / G3: invocation outcome seal.
--
-- Once an invocation is `executing`, its identity, tool, arguments and authorization evidence are frozen; once it is terminal
-- (succeeded, failed, denied, cancelled, expired) every column except the operational `retry_count` is frozen, including status,
-- result, result_hash, error_code, error_message and completed_at.
--
-- The guard compares whole rows (to_jsonb) against an explicit MUTABLE allowlist rather than an explicit frozen list. A column added
-- to the table later is therefore sealed by default (fail closed) until someone deliberately classifies it as mutable. The coverage
-- test (tests/sql/10_invocation_seal_guard.sql) asserts that every live column is classified.
--
-- It is a BEFORE UPDATE trigger with no column list, so no UPDATE OF column-list gap exists. Every existing legitimate writer
-- (kernel authorization, execute-task, approval expiry and convergence, mission-terminal cascade) updates rows whose OLD status is
-- non-terminal, and executing -> terminal writes only status/result/result_hash/error_*/completed_at, so none of them is affected.
--
-- Also blocks TRUNCATE of the invocation ledger (mirrors trg_aios_audit_no_truncate) and revokes the TRUNCATE privilege.
begin;

create or replace function private.aios_invocation_seal_guard() returns trigger
language plpgsql security definer set search_path = '' as $f$
declare
  -- Column classification. Everything NOT listed as mutable for the state is frozen.
  v_terminal   constant text[] := array['succeeded','failed','denied','cancelled','expired'];
  v_exec_mut   constant text[] := array['status','result','result_hash','error_code','error_message','completed_at','retry_count'];
  v_term_mut   constant text[] := array['retry_count'];
  v_mut        text[];
  v_old        jsonb;
  v_new        jsonb;
  v_diff       text;
begin
  -- Row identity and creation time never change in any state.
  if new.id is distinct from old.id or new.created_at is distinct from old.created_at then
    raise exception 'invocation id and created_at are immutable' using errcode = '55000';
  end if;

  if old.status = any (v_terminal) then
    v_mut := v_term_mut;
  elsif old.status = 'executing' then
    v_mut := v_exec_mut;
  else
    return new;  -- pre-execution rows keep their existing, separately guarded lifecycle
  end if;

  v_old := to_jsonb(old) - v_mut;
  v_new := to_jsonb(new) - v_mut;
  if v_old is distinct from v_new then
    select string_agg(e.key, ',' order by e.key) into v_diff
      from jsonb_each(v_old) e where (v_new -> e.key) is distinct from e.value;
    raise exception 'sealed invocation: column(s) [%] are immutable once an invocation is %', v_diff, old.status
      using errcode = '55000';
  end if;
  return new;
end $f$;

revoke all on function private.aios_invocation_seal_guard() from public, anon, authenticated, service_role;

drop trigger if exists trg_aios_invocation_seal_guard on public.aios_tool_invocations;
create trigger trg_aios_invocation_seal_guard before update on public.aios_tool_invocations
  for each row execute function private.aios_invocation_seal_guard();

-- TRUNCATE of the invocation ledger is never legitimate.
create or replace function private.aios_invocation_no_truncate() returns trigger
language plpgsql security definer set search_path = '' as $f$
begin
  raise exception 'TRUNCATE of the invocation ledger is not permitted' using errcode = '55000';
end $f$;
revoke all on function private.aios_invocation_no_truncate() from public, anon, authenticated, service_role;

revoke truncate on public.aios_tool_invocations from service_role, authenticated, anon;
drop trigger if exists trg_aios_invocation_no_truncate on public.aios_tool_invocations;
create trigger trg_aios_invocation_no_truncate before truncate on public.aios_tool_invocations
  for each statement execute function private.aios_invocation_no_truncate();

commit;
