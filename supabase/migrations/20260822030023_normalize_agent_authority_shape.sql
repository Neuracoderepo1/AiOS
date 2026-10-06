-- Reconcile the two authority shapes (demo-seeded agents used
-- {"risk","tools"}; ARBITRON used {"max_risk_level","allowed_tools",...})
-- into one shared contract every future enforcement trigger can rely on:
--
--   { "risk_level": "low|medium|high", "allowed_tools": [...], "limits": {} }
--
-- risk_level and allowed_tools are universal, checked by every agent.
-- limits is a free-form bag for domain-specific caps (financial, rate, etc.)
-- and is empty {} where none apply.

update public.aios_agents
set authority = jsonb_build_object(
  'risk_level', lower(coalesce(authority->>'risk', authority->>'max_risk_level', 'low')),
  'allowed_tools', coalesce(
    authority->'tools',
    authority->'allowed_tools',
    '[]'::jsonb
  ),
  'limits', (authority - 'risk' - 'tools' - 'max_risk_level' - 'allowed_tools')
);
