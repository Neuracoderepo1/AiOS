-- Executor allowlist enforcement (private.aios_validate_executor_registry). Not part of the 46-case matrix; it backs the matrix
-- fixture choice in 05 (which reuses an allowlisted key so budget cases E3/E4 are not masked by this guard).
-- Runs in one rolled-back transaction as the database owner; nothing persists.
begin;
do $$
declare st text; msg text; key text;
begin
  -- 1. Registered, enabled, allowlisted: accepted and returns the executor key.
  key := private.aios_validate_executor_registry('support.search_tickets');
  if key is distinct from 'support.search_tickets.v1' then raise exception 'allowlisted executor not accepted: %', key; end if;

  -- 2. Registered and enabled but with a key outside the allowlist: refused with 42501 / "not allowlisted".
  update private.aios_trusted_executors set executor_key = 'attacker.exec.v1' where tool_key = 'support.search_tickets';
  begin
    perform private.aios_validate_executor_registry('support.search_tickets');
    raise exception 'non-allowlisted executor key was accepted';
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    if st <> '42501' or msg not like '%not allowlisted%' then raise exception 'wrong refusal for non-allowlisted key: % %', st, msg; end if;
  end;

  -- 3. Executor row disabled: refused as not registered.
  update private.aios_trusted_executors set executor_key = 'support.search_tickets.v1', is_enabled = false where tool_key = 'support.search_tickets';
  begin
    perform private.aios_validate_executor_registry('support.search_tickets');
    raise exception 'disabled executor was accepted';
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    if st <> '42501' or msg not like '%not registered%' then raise exception 'wrong refusal for disabled executor: % %', st, msg; end if;
  end;

  -- 4. Unknown tool: refused as unavailable.
  begin
    perform private.aios_validate_executor_registry('no.such.tool');
    raise exception 'unknown tool was accepted';
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    if st <> '42501' or msg not like '%unavailable%' then raise exception 'wrong refusal for unknown tool: % %', st, msg; end if;
  end;
end $$;
rollback;
select 'ok: executor allowlist' as result;
