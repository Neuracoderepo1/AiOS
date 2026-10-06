alter table public.aios_tasks add column if not exists mission_id uuid references public.aios_missions(id) on delete cascade;
create index if not exists idx_aios_tasks_mission on public.aios_tasks(mission_id);
