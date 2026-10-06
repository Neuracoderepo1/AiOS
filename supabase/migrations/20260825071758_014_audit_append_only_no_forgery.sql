
-- Development 4: audit events must not be forgeable by ordinary authenticated
-- users. Confirmed live before this migration: any org member could INSERT a
-- fabricated event like "agent_executed_withdrawal_successfully" directly.
--
-- UPDATE/DELETE were already correctly absent from policy (RLS denies by
-- default with no matching policy) — this migration only needed to remove
-- direct authenticated INSERT. All legitimate audit writes already go through
-- SECURITY DEFINER functions/triggers (aios_enforce_agent_authority,
-- aios_log_tool_invocation_audit, aios_create_agent, etc.), which run as the
-- function owner and are unaffected by removing this policy — only raw
-- client-side REST/table inserts are blocked.

drop policy if exists aios_audit_events_insert on public.aios_audit_events;

-- Cosmetic hygiene while here: two identical SELECT policies existed
-- (aios_audit_events_select and "org members can view their org's audit
-- events") — harmless but redundant; collapse to one.
drop policy if exists "org members can view their org's audit events" on public.aios_audit_events;
