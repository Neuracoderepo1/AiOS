-- aios_approvals and aios_audit_events currently use a single blanket ALL policy
-- gated only on org membership. That means any member (not just admin/owner) can
-- insert, update, or delete approval decisions and audit records — undermining
-- the whole point of an approval gate and an audit trail.
--
-- New model:
--   approvals: members can view/request; only admins can record a decision
--              (update) or delete; still no anon/public exposure.
--   audit_events: members can view/insert (agents and app code need to write
--              events); NO update, NO delete for anyone via the API roles.
--              Audit rows are append-only at the RLS layer. Corrections, if
--              ever needed, happen via service_role outside normal app traffic.

-- ── aios_approvals ──────────────────────────────────────────────
drop policy if exists aios_approvals_member on public.aios_approvals;

create policy aios_approvals_select
  on public.aios_approvals for select
  to authenticated
  using (aios_is_org_member(organization_id));

create policy aios_approvals_insert
  on public.aios_approvals for insert
  to authenticated
  with check (aios_is_org_member(organization_id));

create policy aios_approvals_update
  on public.aios_approvals for update
  to authenticated
  using (aios_is_org_admin(organization_id))
  with check (aios_is_org_admin(organization_id));

create policy aios_approvals_delete
  on public.aios_approvals for delete
  to authenticated
  using (aios_is_org_admin(organization_id));

-- ── aios_audit_events ────────────────────────────────────────────
drop policy if exists aios_audit_member on public.aios_audit_events;

create policy aios_audit_events_select
  on public.aios_audit_events for select
  to authenticated
  using (aios_is_org_member(organization_id));

create policy aios_audit_events_insert
  on public.aios_audit_events for insert
  to authenticated
  with check (aios_is_org_member(organization_id));

-- Deliberately no UPDATE or DELETE policy for authenticated/anon:
-- with RLS enabled and no matching policy, both are denied outright.
-- This makes the audit trail append-only through the normal API surface.
