-- aios_public_metrics() returns platform-wide aggregates across ALL organizations
-- (org counts, agent counts, avg trust score, task/invocation totals, pending approvals)
-- with no org_id scoping. Unauthenticated (anon) access lets anyone scrape
-- cross-tenant adoption/operational metrics via /rest/v1/rpc/aios_public_metrics.
-- Revoking anon execute; authenticated access left in place pending explicit
-- product decision on whether this should be a public marketing-site counter
-- (in which case it should be redesigned to return non-sensitive rounded/bucketed
-- figures only) or an internal authenticated-only dashboard metric.
revoke execute on function public.aios_public_metrics() from anon;
