# AiOS restoration role and migration runbook

## Scope

This runbook describes the database role boundary and safe verification path for Part D restoration. It is not authorization to restore production data, install a restoration credential, grant owner membership, open a restoration window, or deploy a migration.

## Role provisioning contract

The Part D migration creates `aios_restorer` only when it does not already exist. Creation sets all restrictive attributes at role creation time:

- `NOLOGIN`
- `NOINHERIT`
- `NOSUPERUSER`
- `NOCREATEDB`
- `NOCREATEROLE`
- `NOREPLICATION`
- `NOBYPASSRLS`

The migration does not execute `ALTER ROLE`. If an existing role has any unsafe attribute, or if role membership violates either side of the boundary, the migration aborts with SQLSTATE `42501`. It does not repair attributes, revoke memberships, or issue an explicit membership grant. An operator must investigate drift under a separately approved change.

## Implicit creator membership and ADMIN OPTION

PostgreSQL role creation has an important implicit-membership rule. When a non-superuser with `CREATEROLE` creates a role, PostgreSQL automatically grants the creator membership in the newly created role with `ADMIN OPTION`. On supported PostgreSQL versions this creator membership is deliberately non-activating: it has `SET FALSE` and `INHERIT FALSE`. The creator therefore does not automatically inherit `aios_restorer` object privileges and cannot `SET ROLE aios_restorer` through that membership. A superuser instead already has superuser authority; do not expect an ordinary membership row to represent that authority.

`ADMIN OPTION` is materially different from ordinary membership. It permits the holder to grant or revoke membership in `aios_restorer` for other roles. It is therefore privileged membership-administration authority, even when `SET` and `INHERIT` are false. It must be confined to the explicitly approved database-owner/migration-executor identity. It must never be assigned to an application or service runtime identity.

The Part D migration uses `CREATE ROLE aios_restorer ...` only when the role is absent. It does not issue `GRANT aios_restorer TO ...`. The creator-side membership/authority is a PostgreSQL consequence of role creation, not an application grant and not an extra privilege installed by the migration. If `aios_restorer` already exists, the migration does not create it and does not manufacture creator membership; it validates the existing role attributes and membership boundary and fails closed on drift.

## Approved database-owner / migration-executor boundary

The approved authority boundary is:

1. The database owner authorizes the specific migration executor and the isolated migration operation.
2. The migration executor is the only identity permitted to exercise the role-creation authority needed to provision `aios_restorer`. If it is a non-superuser `CREATEROLE` role, its implicit creator membership with `ADMIN OPTION` is expected and must be recorded in CI evidence. If it is a superuser, its inherent authority must be recorded instead.
3. Any later membership grant to the database owner's own login requires a separate, explicit operational approval by the database owner. The migration itself does not perform that grant.
4. No application role, API identity, Edge Function identity, authenticator, `service_role`, or other runtime identity may receive direct or transitive membership in `aios_restorer`, nor may any runtime identity receive `ADMIN OPTION` on it.
5. The `aios_restorer` role itself must not be a member of any other role.

The migration checks the restorer's restrictive attributes, rejects the restorer being a member of another role, and rejects direct or transitive membership by the listed application/service identities. Its restoration authorization checks the real database `session_user` membership. JWT claims and request settings are not authorization inputs.

## Migration execution privileges versus application runtime privileges

Migration execution is a controlled schema/role-provisioning operation performed by the approved database owner or migration executor. Its authority is not part of the application's runtime permission set.

Application runtime identities (`anon`, `authenticated`, `service_role`, `authenticator`, and Edge Function/service identities) must not be granted `CREATEROLE`, privileged database-owner membership, membership in `aios_restorer`, or `ADMIN OPTION` on `aios_restorer`. They must not be able to elevate themselves into the migration executor or owner boundary. The Part D migration explicitly rejects application/service membership in the restorer role and grants restoration-function execution to `aios_restorer`, not to application runtime roles.

The `NOLOGIN` and `NOINHERIT` attributes on `aios_restorer` are additional restrictions; they do not replace the prohibition on granting runtime identities membership. The migration's runtime authorization uses `session_user`, so a JWT claim or a caller-controlled request setting cannot substitute for a real, approved database identity.

## CI verification requirements

The CI replay must use the pinned Supabase CLI version `2.122.0` and a disposable local PostgreSQL stack. Evidence must record:

1. The exact commit SHA, workflow run ID/URL, migration version, and SQLSTATE for any failure.
2. PostgreSQL `server_version`.
3. The actual migration runner (`current_user` and `session_user`) and its `rolsuper`, `rolcreaterole`, `rolinherit`, and `rolcanlogin` attributes.
4. Whether the runner is a superuser or has the expected implicit creator membership and `ADMIN OPTION` on `aios_restorer`; also record the membership's `SET` and `INHERIT` flags where applicable.
5. A disposable `GRANT aios_restorer TO aios_ci_membership_probe` authority test, enclosed in a transaction and rolled back. This is a test-only probe in the disposable database, never a production grant.
6. Negative checks proving application/service identities have no direct or transitive membership and no `ADMIN OPTION` on `aios_restorer`.
7. The static migration guard, restoration SQL regression suite, delete-protection suite, and complete existing SQL/matrix/concurrency/smoke suites.
8. All job outcomes, including skipped steps, failed jobs, logs, and artifact references. Infrastructure failures must be distinguished from SQL/test failures and must be corrected rather than bypassed.

A successful disposable grant test demonstrates the runner's effective authority in that CI database; it does not authorize any production membership change.

## Hosted Supabase bootstrap and rollback

Hosted project provisioning and rollback are environment-specific. Before any hosted action, verify the exact AiOS project reference, current database version, migration history, backup/PITR availability, and the actual migration executor's role attributes and role-membership authority. Confirm a tested rollback or forward-recovery plan with the database owner.

**Read-only hosted inspection (11 November 2026):** the connected Supabase account exposed two AiOS projects. The production project is `jtkcdwhiduixoiodhbfn` (Project AiOS, PostgreSQL 17.6); its hosted migration history contains 117 entries and ends at `20261108130000_aios_invocation_delete_protection`. A read-only catalog probe confirmed that `aios_restorer` is not present, while the invocation delete guard, invocation seal guard, and mission-terminal cascade trigger are present. The probe ran with `current_user = session_user = postgres`; this observation is not evidence that the migration runner or approved creator identity has been validated for a hosted restoration bootstrap.

A separate project, `jgmpodbamtqhofdocvdo` (AiOS branch, PostgreSQL 17.11), was also visible but had zero applied migrations and zero deployed Edge Functions at inspection time. It is not a provisioned hosted verification target.

No hosted migration, bootstrap, rollback, credential operation, membership grant, restoration activation, or production write was attempted. The catalog inspection was read-only. Hosted bootstrap and rollback therefore remain NOT TESTED. Before any hosted write, the database owner must explicitly designate the target project and approve the migration executor, backup/PITR check, recovery plan, and exact operation.

## Production safety boundary

Do not run the restoration flow until the database owner has separately approved the maintenance window, credential custody, owner-login membership, backup validation, restore source, and post-restore verification. Keep the restoration window closed outside that approved operation. This runbook and a green CI result are readiness evidence only, not production certification.
