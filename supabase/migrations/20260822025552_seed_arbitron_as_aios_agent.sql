-- First real tenant of AiOS: ARBITRON v4, modeled from its actual validated
-- risk/execution guards rather than a speculative authority schema.
--
-- Mapping from ARBITRON's real implementation:
--   - Exchange adapters (Binance USDM, Kraken Perp, Alpaca Spot) -> authorized
--     venues in `authority.exchanges`
--   - inFlight mutex / total-budget guard -> `authority.max_concurrent_positions`
--     and `authority.max_position_usd`
--   - LegTimeoutMsByVenue config -> operational config, NOT an authority/risk
--     boundary, so deliberately excluded from `authority` jsonb (it's a
--     performance parameter, not a permission)
--   - Two-leg arb execution + order cancellation -> `authority.allowed_tools`
--   - Validated but not yet running with real capital at scale -> trust_score
--     set conservatively (see note below)

with org as (
  insert into public.aios_organizations (name)
  values ('Morris Fintech Labs')
  returning id
),
dept as (
  insert into public.aios_departments (organization_id, name)
  select id, 'Arbitrage Execution' from org
  returning id, organization_id
)
insert into public.aios_agents (
  organization_id,
  department_id,
  agent_key,
  name,
  role,
  status,
  primary_model,
  trust_score,
  authority,
  metadata
)
select
  dept.organization_id,
  dept.id,
  'arbitron-v4-engine',
  'ARBITRON v4',
  'arbitrage_execution_engine',
  'idle',
  null, -- not an LLM-driven agent; deterministic Go execution engine
  55.00, -- ASSUMPTION: mid-range trust score — 7 consecutive clean two-leg
         -- arbs validated in testing, but zero live-capital track record yet.
         -- Flag this for Derrick to set explicitly once a trust_score scale
         -- (0-100? 0-1?) is formally defined.
  jsonb_build_object(
    'exchanges', jsonb_build_array('binance_usdm', 'kraken_perp', 'alpaca_spot'),
    'allowed_tools', jsonb_build_array('execute_two_leg_arb', 'cancel_order', 'query_orderbook'),
    'max_position_usd', 5000,
    'max_concurrent_positions', 1,
    'max_risk_level', 'medium',
    'requires_approval_above_usd', 1000
  ),
  jsonb_build_object(
    'source', 'ARBITRON v4 (Go)',
    'validated_run', '7 consecutive clean two-leg arbs, in-flight skip verified',
    'exchange_adapters_validated', jsonb_build_array('binance', 'kraken', 'alpaca')
  )
from dept;
