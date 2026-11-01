-- A2: state the intended final grant policy explicitly.
-- aios_platform_metrics: platform-wide aggregates across all organizations -> service_role only.
revoke all on function public.aios_platform_metrics() from public, anon, authenticated;
grant execute on function public.aios_platform_metrics() to service_role;
comment on function public.aios_platform_metrics() is 'FINAL POLICY: service_role only. Returns cross-organization aggregates.';

-- aios_public_metrics: org-scoped, membership-checked inside the function -> authenticated + service_role, never anon.
revoke all on function public.aios_public_metrics(uuid) from public, anon;
grant execute on function public.aios_public_metrics(uuid) to authenticated, service_role;
comment on function public.aios_public_metrics(uuid) is 'FINAL POLICY: authenticated + service_role. Caller must be an org member (checked in private.aios_public_metrics).';

-- Duplicate unique index on (organization_id, idempotency_key): keep uq_aios_invocation_idempotency.
do $$
begin
  if exists (select 1 from pg_constraint where conindid = 'public.aios_invocations_org_idempotency_key_idx'::regclass) then
    raise notice 'redundant index backs a constraint; not dropping';
  else
    drop index public.aios_invocations_org_idempotency_key_idx;
  end if;
end $$;
