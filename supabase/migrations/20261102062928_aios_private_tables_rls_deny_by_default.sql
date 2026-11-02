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
