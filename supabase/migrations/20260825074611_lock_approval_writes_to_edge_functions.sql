
-- aios_approvals_insert currently lets ANY org member (not just an admin)
-- insert a row with status='approved' directly. aios_enforce_agent_authority
-- treats a matching approved row as a valid human sign-off and auto-clears
-- the blocked invocation — so this is a real self-approval privilege
-- escalation, not a cosmetic issue. review-approval (service role, and it
-- already checks aios_is_org_admin) is the only path that should ever write
-- here now that it exists.
drop policy if exists aios_approvals_insert on public.aios_approvals;
drop policy if exists aios_approvals_update on public.aios_approvals;

-- aios_tool_invocations_update let an org admin flip status directly,
-- bypassing review-approval's task/mission handoff entirely — silently
-- reintroducing the exact "task stuck at blocked_pending_approval forever"
-- bug review-approval v3/v4 was written to fix. execute-task and
-- review-approval both already write here via the service-role client, so
-- no legitimate authenticated-direct path is lost.
drop policy if exists aios_tool_invocations_update on public.aios_tool_invocations;

-- aios_tool_invocations_insert let any org member bypass invoke-tool's
-- agent lookup + requested_by attribution (needed by the audit trigger) via
-- a raw table insert. invoke-tool (service role) is now the only intended
-- write path.
drop policy if exists aios_tool_invocations_insert on public.aios_tool_invocations;
