-- Close the audit-trail gap: previously aios_audit_events depended entirely on
-- application code remembering to write to it, which is why it had 1 row against
-- 4 tool_invocations. This makes every tool invocation structurally guaranteed
-- to produce an audit record, matching the "immutable, cannot be forgotten" claim.

create or replace function public.aios_log_tool_invocation_audit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  insert into public.aios_audit_events(
    organization_id, agent_id, task_id, event_type, risk_level, action, decision, metadata
  ) values (
    new.organization_id,
    new.agent_id,
    new.task_id,
    'tool_invocation',
    new.risk_level,
    new.tool_name,
    new.status,
    jsonb_build_object(
      'tool_invocation_id', new.id,
      'arguments', new.arguments,
      'result', new.result
    )
  );
  return new;
end;
$$;

create trigger aios_tool_invocations_audit_log
after insert or update of status on public.aios_tool_invocations
for each row execute function public.aios_log_tool_invocation_audit();
