-- The authority-enforcement function is a BEFORE INSERT trigger on aios_tool_invocations.
-- Trigger firing does not require EXECUTE privilege on the underlying function for the
-- firing role, so revoking direct RPC-callable EXECUTE here closes the anon/authenticated
-- exposure flagged by the security advisor without affecting real enforcement behavior.
revoke execute on function public.aios_enforce_agent_authority() from public, anon, authenticated;

-- aios_public_metrics() is intentionally public (powers the landing page stat strip),
-- so it is deliberately left grantable to anon and is not touched here.
