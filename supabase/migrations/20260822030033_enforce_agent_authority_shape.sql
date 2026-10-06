-- Lock in the authority contract at the schema level so future inserts/updates
-- can't silently drift back into two incompatible shapes. Requires the three
-- top-level keys to exist with correct types; does not constrain the contents
-- of `limits` since that's intentionally domain-specific.

alter table public.aios_agents
add constraint aios_agents_authority_shape check (
  jsonb_typeof(authority->'risk_level') = 'string'
  and (authority->>'risk_level') in ('low', 'medium', 'high')
  and jsonb_typeof(authority->'allowed_tools') = 'array'
  and jsonb_typeof(authority->'limits') = 'object'
);
