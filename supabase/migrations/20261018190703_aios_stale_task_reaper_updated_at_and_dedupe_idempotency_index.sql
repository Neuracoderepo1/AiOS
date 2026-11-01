alter table public.aios_tasks add column if not exists updated_at timestamptz not null default now();

create or replace function private.aios_touch_updated_at() returns trigger language plpgsql security definer set search_path = '' as $f$ begin new.updated_at := now(); return new; end $f$;
revoke all on function private.aios_touch_updated_at() from public, anon, authenticated;
drop trigger if exists trg_aios_tasks_touch_updated_at on public.aios_tasks;
create trigger trg_aios_tasks_touch_updated_at before update on public.aios_tasks for each row execute function private.aios_touch_updated_at();

create or replace function public.aios_reap_stale_tasks(p_max_age interval default interval '30 minutes')
returns integer language plpgsql security definer set search_path = '' as $f$
declare v_count integer;
begin
  update public.aios_tasks t
     set status = 'failed',
         result = coalesce(t.result, '{}'::jsonb) || jsonb_build_object('error', jsonb_build_object(
           'code','stale_running_task','stage','reaper','reaped_at', now(),
           'tool_already_succeeded', exists(select 1 from public.aios_tool_invocations i where i.task_id=t.id and i.organization_id=t.organization_id and i.status='succeeded')))
   where t.status = 'running'
     and coalesce(t.started_at, t.created_at) < now() - p_max_age
     and not exists (select 1 from public.aios_tool_invocations i where i.task_id=t.id and i.organization_id=t.organization_id and i.status in ('requires_approval','approved','requested'));
  get diagnostics v_count = row_count;
  return v_count;
end $f$;
revoke all on function public.aios_reap_stale_tasks(interval) from public, anon, authenticated;
grant execute on function public.aios_reap_stale_tasks(interval) to service_role;

drop index if exists public.aios_invocations_org_idempotency_key_idx;
