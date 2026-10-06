-- aios_tool_invocations previously had one blanket "ALL" policy for any org member,
-- meaning any member (not just the system) could UPDATE or DELETE a completed
-- invocation record after the fact. That undermines the "verified, not claimed"
-- claim, since this table IS the enforcement evidence, not just a convenience log.
-- Replacing with: members can insert and read; only admins can update (e.g. to
-- record real completion after downstream execution); nobody can delete.

drop policy if exists aios_tools_member on public.aios_tool_invocations;

create policy aios_tool_invocations_select on public.aios_tool_invocations
  for select to authenticated
  using (aios_is_org_member(organization_id));

create policy aios_tool_invocations_insert on public.aios_tool_invocations
  for insert to authenticated
  with check (aios_is_org_member(organization_id));

create policy aios_tool_invocations_update on public.aios_tool_invocations
  for update to authenticated
  using (aios_is_org_admin(organization_id))
  with check (aios_is_org_admin(organization_id));

-- Deliberately no delete policy: once logged, a tool invocation record is permanent,
-- matching the same immutability guarantee as aios_audit_events.
