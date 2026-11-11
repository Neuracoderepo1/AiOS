# AiOS restoration role and migration runbook

## Scope

This runbook describes the database role boundary and the safe verification path for Part D restoration. It is not authorization to restore production data, install a restoration credential, grant owner membership, open a restoration window, or deploy a migration.

## Role provisioning contract

The Part D migration creates `aios_restorer` only when it does not already exist. Creation sets all restrictive attributes at role creation time:

- `NOLOGIN`
- `NOINHERIT`
- `NOSUPERUSER`
- `NOCREATEDB`
- `NOCREATEROLE`
- `NOREPLICATION`
- `NOBYPASSRLS`

The migration does not execute `ALTER ROLE`. If an existing role has any unsafe attribute, or if role membership violates either side of the boundary, the migration aborts with SQLSTATE `42501`. It does not repair attributes, revoke memberships, or grant memberships. An operator must investigate drift under a separately approved change.

## Membership contract

Membership in `aios_restorer` is an owner-controlled, out-of-band operation. Only the database owner may grant it to the owner's own login after a separately authorized operational review. No application, API, service, authenticator, or Edge Function identity may be a direct or transitive member. The restorer itself must not be a member of any other role.

The migration provisions no owner membership and does not install or rotate credentials. The restoration API authorizes using the actual `session_user` membership, not JWT claims or request settings.

## CI verification requirements

The CI replay must use the pinned Supabase CLI version `2.122.0` and a disposable local PostgreSQL stack. Evidence must record:

1. The migration version and SQLSTATE for any failure.
2. PostgreSQL `server_version`.
3. The actual migration runner (`current_user`) and its `rolsuper`, `rolcreaterole`, `rolinherit`, and `rolcanlogin` attributes.
4. Whether the runner has `ADMIN OPTION` on `aios_restorer`.
5. A disposable `GRANT aios_restorer TO aios_ci_membership_probe` authority test, enclosed in a transaction and rolled back.
6. The static migration guard, restoration SQL regression suite, and complete existing SQL/matrix/concurrency/smoke suites.

A successful disposable grant test demonstrates the runner's effective authority in that CI database; it does not authorize any production membership change.

## Hosted Supabase bootstrap and rollback

Hosted project provisioning and rollback are environment-specific. Before any hosted action, verify the exact AiOS project reference, current database version, migration history, backup/PITR availability, and the actual migration executor's role attributes and role-membership authority. Confirm a tested rollback or forward-recovery plan with the database owner.

**Current Agent 004 evidence limitation:** the connected Supabase projects available during this task did not include the AiOS project reference. No hosted AiOS bootstrap, rollback, SQL query, migration, credential operation, membership grant, or restoration activation was attempted. Hosted capability therefore remains unverified and must not be inferred from local CI success.

## Production safety boundary

Do not run the restoration flow until the database owner has separately approved the maintenance window, credential custody, owner-login membership, backup validation, restore source, and post-restore verification. Keep the restoration window closed outside that approved operation. This runbook and a green CI result are readiness evidence only, not production certification.
