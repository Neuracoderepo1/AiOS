-- aios_audit_events has RLS enabled with zero policies today, meaning it's
-- correctly locked to service_role only — but that also means org members
-- have no way to actually see their own audit trail. Per the WARDEN
-- directive, audit history must be visible and append-only, not simply
-- inaccessible. This adds SELECT only, scoped to org membership; no
-- INSERT/UPDATE/DELETE policy is added, so the table remains writable
-- only by service_role and the SECURITY DEFINER trigger functions that
-- are already locked down to service_role/postgres.
CREATE POLICY "org members can view their org's audit events"
  ON public.aios_audit_events
  FOR SELECT
  TO authenticated
  USING (public.aios_is_org_member(organization_id));
