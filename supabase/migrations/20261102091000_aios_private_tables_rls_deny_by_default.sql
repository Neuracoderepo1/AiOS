-- Private-schema tables are server-only. Access model (as designed in 20260826143937 and 20261101230000):
--   * client roles (anon, authenticated) hold NO table privileges in schema private (only USAGE on the schema, needed so RLS policies
--     can call the two executable membership helpers);
--   * private tables are read/written only by SECURITY DEFINER functions running as the owner.
-- Until now this was enforced by grants alone. Add deny-by-default RLS (enabled, zero policies) as a second layer so a future
-- accidental GRANT cannot expose a private table to a client role. The owner is not FORCEd, so the SECURITY DEFINER functions that
-- own this access path are unaffected. Idempotent; covers every current and (on re-run) future table in schema private.
do $$
declare t record;
begin
  for t in
    select c.oid::regclass as rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'private' and c.relkind in ('r', 'p')
  loop
    execute format('alter table %s enable row level security', t.rel);
    execute format('revoke all on table %s from public, anon, authenticated', t.rel);
  end loop;
end $$;
