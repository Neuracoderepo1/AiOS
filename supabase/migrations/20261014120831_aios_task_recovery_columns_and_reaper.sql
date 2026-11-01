-- A1: give tasks an age signal and failure diagnostics, plus an idempotent stale-task reaper.
alter table public.aios_tasks
  add column if not exists updated_at timestamptz,
  add column if not exists failed_stage text,
  add column if not exists last_error text;

-- Backfill without tripping the status guard on historical rows.
alter table public.aios_tasks disable trigger trg_aios_task_status_guard;
update public.aios_tasks set updated_at = coalesce(completed_at, started_at, created_at) where updated_at is null;
alter table public.aios_tasks enable trigger trg_aios_task_status_guard;

alter table public.aios_tasks
  alter column updated_at set default now(),
  alter column updated_at set not null;

create or replace function private.aios_touch_task_updated_at()
returns trigger language plpgsql security definer set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;

drop trigger if exists trg_aios_tasks_touch_updated_at on public.aios_tasks;
create trigger trg_aios_tasks_touch_updated_at
  before update on public.aios_tasks
  for each row execute function private.aios_touch_task_updated_at();

create index if not exists idx_aios_tasks_status_updated_at on public.aios_tasks (status, updated_at);

-- Reaper: converges stale 'running' tasks to a documented state. Safe to repeat. Never re-executes a tool.
create or replace function private.aios_reap_stale_tasks(p_max_age interval default interval '10 minutes')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r record;
  inv record;
  v_failed int := 0; v_blocked int := 0; v_skipped int := 0;
  v_stage text; v_note text;
begin
  for r in
    select t.id, t.organization_id, t.mission_id
    from public.aios_tasks t
    where t.status = 'running' and t.updated_at < now() - p_max_age
    order by t.updated_at
    for update skip locked
  loop
    select i.id, i.status into inv
    from public.aios_tool_invocations i
    where i.task_id = r.id and i.organization_id = r.organization_id
    order by i.created_at desc limit 1;

    if found and inv.status = 'requires_approval' then
      update public.aios_tasks set status = 'blocked_pending_approval'
        where id = r.id and status = 'running';
      update public.aios_missions set status = 'blocked_pending_approval'
        where id = r.mission_id and status = 'running';
      v_blocked := v_blocked + 1;

    elsif found and inv.status not in ('succeeded', 'failed', 'denied') then
      -- executing / approved / unknown: the tool may be in flight. Do not guess; leave for an operator.
      v_skipped := v_skipped + 1;

    else
      if not found then
        v_stage := 'before_invocation';
        v_note := 'Task stalled before any tool invocation was recorded (model proposal stage). No tool was executed.';
      elsif inv.status = 'succeeded' then
        v_stage := 'final_analysis';
        v_note := 'Tool already succeeded; task stalled during final analysis. Tool result is preserved on the invocation and was not re-executed.';
      else
        v_stage := 'invocation_' || inv.status;
        v_note := 'Invocation reached terminal state ' || inv.status || ' but the task was not closed.';
      end if;

      update public.aios_tasks
        set status = 'failed', failed_stage = v_stage, last_error = v_note,
            result = coalesce(result, '{}'::jsonb) || jsonb_build_object(
              'error', 'stale_task_reaped', 'failed_stage', v_stage,
              'invocation_id', case when found then inv.id else null end, 'note', v_note)
        where id = r.id and status = 'running';

      update public.aios_missions m set status = 'failed', completed_at = now()
        where m.id = r.mission_id and m.status = 'running'
          and not exists (
            select 1 from public.aios_tasks s
            where s.mission_id = m.id
              and s.status in ('queued','assigned','ready','running','approved','blocked_pending_approval'));
      v_failed := v_failed + 1;
    end if;
  end loop;

  return jsonb_build_object('failed', v_failed, 'blocked_pending_approval', v_blocked, 'skipped_needs_operator', v_skipped, 'max_age', p_max_age::text);
end; $$;

revoke all on function private.aios_reap_stale_tasks(interval) from public, anon, authenticated;
grant execute on function private.aios_reap_stale_tasks(interval) to service_role;
comment on function private.aios_reap_stale_tasks(interval) is 'Reconciles stale running tasks against invocation state. Idempotent. Never re-executes tools. Executing/approved invocations are left for an operator.';
