begin;
alter table public.aios_approvals drop constraint if exists aios_approvals_invocation_id_fkey;
alter table public.aios_approvals add constraint aios_approvals_invocation_id_fkey foreign key(invocation_id) references public.aios_tool_invocations(id) deferrable initially deferred;
commit;
