# AiOS client-exposed RPC and trusted-executor security boundary

**Status:** intentional exposure contract; regression-tested in the candidate branch  
**Scope:** public.aios_agent_trust_explain(uuid), public.aios_current_org_role(uuid), public.aios_public_metrics(uuid), and private.aios_trusted_executors

## Authenticated SECURITY DEFINER RPCs

The following three public RPCs are intentionally callable by authenticated users because the application uses them to display organization-scoped governance information:

| RPC | Intended result | Authorization boundary |
|---|---|---|
| public.aios_agent_trust_explain(uuid) | Explain the stored/computed trust signals for one agent | Resolves the agent's organization and requires the caller to be a member of that organization; non-members receive an authorization error |
| public.aios_current_org_role(uuid) | Return the caller's role in the requested organization | Returns only the role belonging to auth.uid() in that organization; it is not a role lookup for arbitrary users |
| public.aios_public_metrics(uuid) | Return organization-level operational metrics | Requires the caller to be a member of the requested organization; non-members receive an authorization error |

These are deliberate authenticated API boundaries, not anonymous endpoints. Their security contract is:

1. SECURITY DEFINER is retained only because the functions need controlled access to protected organization data.
2. Each function pins an empty search_path; protected objects are schema-qualified.
3. authenticated receives EXECUTE.
4. anon and PUBLIC receive no EXECUTE. No default PUBLIC grant is permitted.
5. Authorization is based on the authenticated database identity and organization membership, never caller-supplied user IDs or editable user metadata.
6. A successful RPC call does not grant access to the underlying private implementation or table.

Supabase's authenticated-SECURITY-DEFINER advisor warning is expected for these three functions. It must not be dismissed without preserving the function-level membership checks and regression suite. The advisor is an inventory signal, not by itself proof of an exploitable authorization flaw.

## Trusted executor registry

private.aios_trusted_executors is intentionally server-only. It maps a registered tool key to an allowlisted executor implementation. It is not an application-readable registry.

- RLS is enabled.
- The table has zero RLS policies by design. This is deny-by-default, not an accidental missing policy.
- PUBLIC, anon, authenticated, and service_role receive no direct table privileges.
- private.aios_validate_executor_registry(text) is not directly executable by client or service roles.
- The private kernel authorization function reads and validates the registry through its SECURITY DEFINER execution path, after checking the service-role execution context, canonical tool registry, active contract, invocation binding, argument hash, and approval state.

The Supabase rls_enabled_no_policy INFO finding for this table is expected. Do not add a permissive policy or grant direct table access merely to silence the advisor. Any future registry administration UI requires a separately authorized server-side administrative operation, not direct table access.

## Regression coverage

- tests/sql/02_function_privilege_boundary.sql checks that the three public wrappers remain SECURITY DEFINER, pin a search_path, are executable by authenticated, and are not executable by anon or PUBLIC. It exercises authenticated/service-role calls against unknown organization/agent identifiers and verifies anonymous calls are rejected.
- tests/sql/15_trusted_executor_registry_boundary.sql verifies RLS is enabled, no policies exist, PUBLIC/client/service roles have no direct table privileges, and the validator function is not directly executable by those roles.
- tests/sql/06_executor_allowlist.sql verifies the registered executor allowlist, disabled executor rejection, and unknown-tool rejection.
- The CI SQL regression runner executes every tests/sql/*.sql file against the fresh migration replay database.

## Remaining owner-controlled setting

Leaked-password protection is a Supabase Auth configuration setting, not a SQL migration. It remains an owner/security decision and is not changed by these repository tests or documentation. Enablement must be reviewed against the organization's password and sign-in policy before changing hosted Auth configuration.
