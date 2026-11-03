-- Production applied this as a separate migration (version 20261102062940). The repository's view migration (20261102062924)
-- already carries the same grants, so this file is an idempotent restatement kept only so repository and production
-- migration versions match (Supabase Preview requires every remote version to exist locally).
revoke all on public.aios_backlog_effective_dispositions from public, anon, authenticated;
grant select on public.aios_backlog_effective_dispositions to authenticated, service_role;
revoke insert, update, delete, truncate, references, trigger on public.aios_backlog_effective_dispositions from service_role;
