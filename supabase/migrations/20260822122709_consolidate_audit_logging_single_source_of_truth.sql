-- Finding: both invoke-tool and review-approval Edge Functions already write their
-- own audit_events rows with richer context (requested_by, reviewed_by, reason)
-- than the generic trigger I added earlier tonight. That trigger now ALSO fires on
-- every insert/status-update those functions make, so every real call through the
-- actual API produces two audit rows instead of one. Fixing by making the trigger
-- the single source of truth with equal or better context, then stripping the
-- duplicate manual inserts from both functions (next step, outside SQL).

alter table public.aios_tool_invocations
  add column if not exists requested_by uuid references auth.users(id);

create or replace function public.aios_log_tool_invocation_audit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_approval record;
begin
  if tg_op = 'INSERT' then
    insert into public.aios_audit_events(
      organization_id, agent_id, task_id, event_type, risk_level, action, decision, metadata
    ) values (
      new.organization_id, new.agent_id, new.task_id,
      'tool_invocation_requested', new.risk_level, new.tool_name,
      case when new.status = 'requires_approval' then 'held_for_approval' else 'auto_approved' end,
      jsonb_build_object(
        'invocation_id', new.id,
        'arguments', new.arguments,
        'requested_by', new.requested_by
      )
    );
    return new;
  end if;

  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status in ('approved', 'rejected') then
      select reviewed_by, reason into v_approval from public.aios_approvals where id = new.approval_id;
      insert into public.aios_audit_events(
        organization_id, agent_id, task_id, event_type, risk_level, action, decision, metadata
      ) values (
        new.organization_id, new.agent_id, new.task_id,
        'tool_invocation_reviewed', new.risk_level, new.tool_name, new.status,
        jsonb_build_object(
          'invocation_id', new.id,
          'approval_id', new.approval_id,
          'reviewed_by', v_approval.reviewed_by,
          'reason', v_approval.reason
        )
      );
    else
      insert into public.aios_audit_events(
        organization_id, agent_id, task_id, event_type, risk_level, action, decision, metadata
      ) values (
        new.organization_id, new.agent_id, new.task_id,
        'tool_invocation_status_changed', new.risk_level, new.tool_name, new.status,
        jsonb_build_object('invocation_id', new.id, 'previous_status', old.status)
      );
    end if;
  end if;

  return new;
end;
$$;
