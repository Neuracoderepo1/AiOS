-- PART D: controlled, owner-only restoration of the audit store, with catalog-based guarded-trigger drift detection.
--
-- DESIGN (see docs/security/RESTORATION-RUNBOOK.md, docs/engineering/LOCK-ORDER.md):
--   * `aios_restorer` is a NOLOGIN role. Membership is granted ONLY by the database owner to the owner's own login.
--     No application role (anon, authenticated, service_role, authenticator) may be a member; no Edge Function can open a window.
--   * All restoration functions live in schema `private`, are SECURITY DEFINER with search_path='', and are EXECUTE-able
--     by `aios_restorer` only. Each also checks the *session* user's membership (JWT claims are never used for authorization).
--   * The restoration window is a persisted state machine: closed | open | closed_verification_failed | guard_reenable_failed.
--     A verification failure can never undo trigger re-enablement (see aios_restoration_close_internal).
--   * The single canonical final verifier is private.aios_final_verify (defined in the Part E migration); this migration
--     deliberately defines NO verifier so there is exactly one implementation.
--   * Trigger drift is detected by catalog fingerprints (timing/events/WHEN/args/function identity and function body), not names.
--
-- This migration also hardens the existing audit protections it depends on:
--   * audit triggers become ENABLE ALWAYS (they previously fired only for session_replication_role='origin', so a role able to
--     set session_replication_role='replica' bypassed hash chaining and immutability);
--   * service_role keeps SELECT/INSERT on aios_audit_events but loses UPDATE/DELETE/TRUNCATE/TRIGGER/REFERENCES. (UPDATE/DELETE were already blocked by
--     triggers; TRIGGER would have let service_role attach a trigger to the audit table.)

-- 0. Role -------------------------------------------------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'aios_restorer') then
    create role aios_restorer nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
  end if;
end $$;
alter role aios_restorer nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
grant usage on schema private to aios_restorer;

-- 1. Harden existing audit protections (reconcile with 20260825*/20261106193358; nothing is duplicated) ------------------
alter table public.aios_audit_events enable always trigger trg_aios_audit_hash;
alter table public.aios_audit_events enable always trigger trg_aios_audit_immutable_update;
alter table public.aios_audit_events enable always trigger trg_aios_audit_immutable_delete;
alter table public.aios_audit_events enable always trigger trg_aios_audit_no_truncate;
revoke update, delete, truncate, trigger, references on public.aios_audit_events from public, anon, authenticated, service_role;

-- 2. State, credentials, registry, log -------------------------------------------------------------------------------
create table if not exists private.aios_restoration_state (
  id                       int primary key default 1 check (id = 1),
  generation               bigint not null default 0,
  status                   text not null default 'closed'
                           check (status in ('closed', 'open', 'closed_verification_failed', 'guard_reenable_failed')),
  window_id                uuid,
  opened_at                timestamptz,
  expires_at               timestamptz,
  opened_by                name,
  reason                   text,
  closed_at                timestamptz,
  close_actor              text,
  last_failure             jsonb,
  updated_at               timestamptz not null default clock_timestamp()
);
insert into private.aios_restoration_state (id) values (1) on conflict (id) do nothing;

create table if not exists private.aios_restoration_credentials (
  id                  bigint generated always as identity primary key,
  credential_hash     text not null,              -- crypt(bf, cost 12) hash only; plaintext is never stored
  installed_at        timestamptz not null default clock_timestamp(),
  installed_by        name not null default session_user,
  consumed_at         timestamptz,
  consumed_by         name,
  consumed_window_id  uuid,
  revoked_at          timestamptz,
  revoked_reason      text
);
create unique index if not exists aios_restoration_one_active_credential
  on private.aios_restoration_credentials ((true)) where consumed_at is null and revoked_at is null;

create table if not exists private.aios_restoration_log (
  id             bigint generated always as identity primary key,
  at             timestamptz not null default clock_timestamp(),
  generation     bigint,
  window_id      uuid,
  event          text not null,
  actor          name not null default session_user,
  details        jsonb not null default '{}'::jsonb
);

create table if not exists private.aios_guarded_triggers (
  id                   bigint generated always as identity primary key,
  schema_name          name not null,
  table_name           name not null,
  trigger_name         name not null,
  expected_enabled     "char" not null check (expected_enabled in ('O', 'A')),
  expected_trigger_fp  text not null,
  expected_function    text not null,
  expected_function_fp text not null,
  restorable           boolean not null default false,   -- member of the approved disable set during a restoration window
  registered_at        timestamptz not null default clock_timestamp(),
  registered_by        name not null default session_user,
  unique (schema_name, table_name, trigger_name)
);

alter table private.aios_restoration_state       enable row level security;
alter table private.aios_restoration_credentials enable row level security;
alter table private.aios_restoration_log         enable row level security;
alter table private.aios_guarded_triggers        enable row level security;
revoke all on private.aios_restoration_state, private.aios_restoration_credentials,
              private.aios_restoration_log, private.aios_guarded_triggers from public, anon, authenticated, service_role, aios_restorer;

-- append-only restoration log (ENABLE ALWAYS so session_replication_role cannot bypass it)
create or replace function private.aios_append_only_guard() returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  raise exception '% on % is not permitted: append-only', tg_op, tg_table_name using errcode = '42501';
end $fn$;
revoke all on function private.aios_append_only_guard() from public, anon, authenticated, service_role;

drop trigger if exists trg_aios_restoration_log_no_mutate on private.aios_restoration_log;
create trigger trg_aios_restoration_log_no_mutate before update or delete on private.aios_restoration_log
  for each row execute function private.aios_append_only_guard();
drop trigger if exists trg_aios_restoration_log_no_truncate on private.aios_restoration_log;
create trigger trg_aios_restoration_log_no_truncate before truncate on private.aios_restoration_log
  for each statement execute function private.aios_append_only_guard();
alter table private.aios_restoration_log enable always trigger trg_aios_restoration_log_no_mutate;
alter table private.aios_restoration_log enable always trigger trg_aios_restoration_log_no_truncate;

-- 3. Fingerprints (catalog-based; no dependence on search_path or trigger names) ----------------------------------------
create or replace function private.aios_function_fingerprint(p_oid oid) returns text
language sql stable security definer set search_path = '' as $fn$
  select encode(extensions.digest(concat_ws('|', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid),
           p.prosecdef::text, pg_get_userbyid(p.proowner)::text, coalesce(p.proconfig::text, ''), l.lanname, p.provolatile::text, p.prosrc), 'sha256'), 'hex')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang where p.oid = p_oid
$fn$;

create or replace function private.aios_trigger_fingerprint(p_oid oid) returns text
language sql stable security definer set search_path = '' as $fn$
  -- tgenabled is deliberately excluded (compared separately); tgtype encodes timing, row/statement level and events.
  select encode(extensions.digest(concat_ws('|', ns.nspname, c.relname, t.tgname, t.tgtype::text,
           pn.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
           coalesce(pg_get_expr(t.tgqual, t.tgrelid), ''),
           coalesce((select string_agg(a.attname, ',' order by a.attnum) from pg_attribute a where a.attrelid = t.tgrelid and a.attnum = any (t.tgattr)), ''),
           encode(t.tgargs, 'hex'), t.tgdeferrable::text, t.tginitdeferred::text, coalesce(t.tgoldtable, ''), coalesce(t.tgnewtable, '')), 'sha256'), 'hex')
  from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace ns on ns.oid = c.relnamespace
  join pg_proc p on p.oid = t.tgfoid join pg_namespace pn on pn.oid = p.pronamespace where t.oid = p_oid
$fn$;
revoke all on function private.aios_function_fingerprint(oid), private.aios_trigger_fingerprint(oid) from public, anon, authenticated, service_role;

-- 4. Role-boundary and authorization ---------------------------------------------------------------------------------------
create or replace function private.aios_restorer_boundary_violations() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare v jsonb := '[]'::jsonb; r record;
begin
  select * into r from pg_roles where rolname = 'aios_restorer';
  if not found then return jsonb_build_array('role_missing'); end if;
  if r.rolcanlogin  then v := v || '"restorer_can_login"'::jsonb; end if;
  if r.rolsuper     then v := v || '"restorer_is_superuser"'::jsonb; end if;
  if r.rolcreaterole or r.rolcreatedb or r.rolreplication or r.rolbypassrls then v := v || '"restorer_has_extra_attributes"'::jsonb; end if;
  if exists (select 1 from pg_auth_members m where m.member = r.oid) then v := v || '"restorer_is_member_of_other_roles"'::jsonb; end if;
  -- application/service roles (and anything that can log in via PostgREST) must NOT be members, directly or transitively
  for r in select rolname from pg_roles
           where rolname in ('anon', 'authenticated', 'service_role', 'authenticator', 'supabase_auth_admin', 'supabase_storage_admin', 'supabase_functions_admin')
             and not rolsuper loop
    if pg_has_role(r.rolname, 'aios_restorer', 'MEMBER') then v := v || to_jsonb('app_role_is_member:' || r.rolname); end if;
  end loop;
  if has_schema_privilege('public', 'private', 'USAGE') then v := v || '"public_has_private_schema_usage"'::jsonb; end if;
  return v;
end $fn$;

create or replace function private.aios_assert_restorer() returns void
language plpgsql stable security definer set search_path = '' as $fn$
declare v jsonb;
begin
  -- authorization is the SESSION user's real database membership. JWT claims / request.* settings are never consulted.
  if session_user in ('anon', 'authenticated', 'service_role', 'authenticator', 'supabase_auth_admin', 'supabase_storage_admin') then
    raise exception 'restoration is not available to application roles' using errcode = '42501';
  end if;
  if not pg_has_role(session_user, 'aios_restorer', 'MEMBER') then
    raise exception 'restoration requires owner membership in aios_restorer' using errcode = '42501';
  end if;
  v := private.aios_restorer_boundary_violations();
  if v <> '[]'::jsonb then
    raise exception 'restorer role boundary violated: %', v using errcode = '42501';
  end if;
end $fn$;
revoke all on function private.aios_restorer_boundary_violations(), private.aios_assert_restorer() from public, anon, authenticated, service_role;

create or replace function private.aios_restoration_log_event(p_event text, p_details jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $fn$
declare st private.aios_restoration_state;
begin
  select * into st from private.aios_restoration_state where id = 1;
  insert into private.aios_restoration_log (generation, window_id, event, details) values (st.generation, st.window_id, p_event, coalesce(p_details, '{}'::jsonb));
end $fn$;
revoke all on function private.aios_restoration_log_event(text, jsonb) from public, anon, authenticated, service_role;

-- 5. Guard registry maintenance (owner/migration only) ---------------------------------------------------------------------
create or replace function private.aios_guard_register_table(p_schema name, p_table name, p_restorable text[] default '{}') returns int
language plpgsql security definer set search_path = '' as $fn$
declare t record; n int := 0;
begin
  for t in select tg.oid as toid, tg.tgname, tg.tgenabled, tg.tgfoid
           from pg_trigger tg join pg_class c on c.oid = tg.tgrelid join pg_namespace ns on ns.oid = c.relnamespace
           where ns.nspname = p_schema and c.relname = p_table and not tg.tgisinternal loop
    insert into private.aios_guarded_triggers (schema_name, table_name, trigger_name, expected_enabled, expected_trigger_fp,
                                               expected_function, expected_function_fp, restorable)
    select p_schema, p_table, t.tgname,
           case when t.tgenabled = 'A' then 'A' else 'O' end,
           private.aios_trigger_fingerprint(t.toid),
           pn.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
           private.aios_function_fingerprint(t.tgfoid),
           t.tgname = any (p_restorable)
    from pg_proc p join pg_namespace pn on pn.oid = p.pronamespace where p.oid = t.tgfoid
    on conflict (schema_name, table_name, trigger_name) do update
      set expected_enabled = excluded.expected_enabled, expected_trigger_fp = excluded.expected_trigger_fp,
          expected_function = excluded.expected_function, expected_function_fp = excluded.expected_function_fp,
          restorable = excluded.restorable, registered_at = clock_timestamp(), registered_by = session_user;
    n := n + 1;
  end loop;
  return n;
end $fn$;
revoke all on function private.aios_guard_register_table(name, name, text[]) from public, anon, authenticated, service_role;

-- 6. Drift detection ---------------------------------------------------------------------------------------------------------
create or replace function private.aios_guard_drift() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare
  v jsonb := '[]'::jsonb; g record; t record; v_status text; v_expect "char";
begin
  select status into v_status from private.aios_restoration_state where id = 1;
  for g in select * from private.aios_guarded_triggers order by schema_name, table_name, trigger_name loop
    select tg.oid as toid, tg.tgenabled, tg.tgfoid into t
      from pg_trigger tg join pg_class c on c.oid = tg.tgrelid join pg_namespace ns on ns.oid = c.relnamespace
      where ns.nspname = g.schema_name and c.relname = g.table_name and tg.tgname = g.trigger_name and not tg.tgisinternal;
    if not found then
      v := v || jsonb_build_object('kind', 'missing_trigger', 'table', g.schema_name || '.' || g.table_name, 'trigger', g.trigger_name);
      continue;
    end if;
    -- during an OPEN window the approved set is expected to be disabled ('D'); everything else must be unchanged
    v_expect := case when g.restorable and v_status in ('open', 'guard_reenable_failed') then 'D' else g.expected_enabled end;
    if t.tgenabled <> v_expect and not (g.restorable and v_status = 'guard_reenable_failed' and t.tgenabled = g.expected_enabled) then
      v := v || jsonb_build_object('kind', 'enabled_mode_mismatch', 'table', g.schema_name || '.' || g.table_name, 'trigger', g.trigger_name,
                                   'expected', v_expect::text, 'actual', t.tgenabled::text);
    end if;
    if private.aios_trigger_fingerprint(t.toid) <> g.expected_trigger_fp then
      v := v || jsonb_build_object('kind', 'trigger_definition_changed', 'table', g.schema_name || '.' || g.table_name, 'trigger', g.trigger_name);
    end if;
    if private.aios_function_fingerprint(t.tgfoid) <> g.expected_function_fp then
      v := v || jsonb_build_object('kind', 'trigger_function_changed', 'table', g.schema_name || '.' || g.table_name, 'trigger', g.trigger_name,
                                   'function', g.expected_function);
    end if;
  end loop;
  -- unexpected additional triggers on protected tables
  for t in select distinct ns.nspname as sn, c.relname as tn, tg.tgname
           from pg_trigger tg join pg_class c on c.oid = tg.tgrelid join pg_namespace ns on ns.oid = c.relnamespace
           where not tg.tgisinternal
             and exists (select 1 from private.aios_guarded_triggers x where x.schema_name = ns.nspname and x.table_name = c.relname)
             and not exists (select 1 from private.aios_guarded_triggers x where x.schema_name = ns.nspname and x.table_name = c.relname and x.trigger_name = tg.tgname) loop
    v := v || jsonb_build_object('kind', 'unexpected_trigger', 'table', t.sn || '.' || t.tn, 'trigger', t.tgname);
  end loop;
  return jsonb_build_object('drift_count', jsonb_array_length(v), 'findings', v, 'registered_triggers', (select count(*) from private.aios_guarded_triggers),
                            'restoration_status', v_status);
end $fn$;
revoke all on function private.aios_guard_drift() from public, anon, authenticated, service_role;

-- 7. Credential lifecycle ----------------------------------------------------------------------------------------------------
create or replace function private.aios_restoration_install_credential(p_credential text) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
begin
  perform private.aios_assert_restorer();
  if p_credential is null or length(p_credential) < 32 then raise exception 'credential must be at least 32 characters' using errcode = '22023'; end if;
  perform 1 from private.aios_restoration_state where id = 1 for update;      -- serialize with open / rotate
  if exists (select 1 from private.aios_restoration_credentials where consumed_at is null and revoked_at is null) then
    raise exception 'an active credential already exists; use aios_restoration_rotate_credential' using errcode = '55000';
  end if;
  insert into private.aios_restoration_credentials (credential_hash) values (extensions.crypt(p_credential, extensions.gen_salt('bf', 12)));
  perform private.aios_restoration_log_event('credential_installed');
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function private.aios_restoration_rotate_credential(p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare c private.aios_restoration_credentials;
begin
  perform private.aios_assert_restorer();
  if p_new is null or length(p_new) < 32 then raise exception 'credential must be at least 32 characters' using errcode = '22023'; end if;
  perform 1 from private.aios_restoration_state where id = 1 for update;
  select * into c from private.aios_restoration_credentials where consumed_at is null and revoked_at is null for update;
  if not found or c.credential_hash <> extensions.crypt(p_old, c.credential_hash) then
    raise exception 'current credential not verified' using errcode = '28000';
  end if;
  -- revoke + install in ONE transaction: there is never a moment with zero or two active credentials
  update private.aios_restoration_credentials set revoked_at = clock_timestamp(), revoked_reason = 'rotated' where id = c.id;
  insert into private.aios_restoration_credentials (credential_hash) values (extensions.crypt(p_new, extensions.gen_salt('bf', 12)));
  perform private.aios_restoration_log_event('credential_rotated');
  return jsonb_build_object('ok', true);
end $fn$;

-- 8. Open ----------------------------------------------------------------------------------------------------------------------
create or replace function private.aios_restoration_open(p_credential text, p_reason text, p_ttl interval default interval '30 minutes') returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare st private.aios_restoration_state; c private.aios_restoration_credentials; g record; v_win uuid := gen_random_uuid(); v_fail int; v_n int := 0;
begin
  perform private.aios_assert_restorer();
  if p_reason is null or length(btrim(p_reason)) < 10 then raise exception 'a reason of at least 10 characters is required' using errcode = '22023'; end if;
  if p_ttl is null or p_ttl < interval '1 minute' or p_ttl > interval '4 hours' then raise exception 'ttl must be between 1 minute and 4 hours' using errcode = '22023'; end if;
  select * into st from private.aios_restoration_state where id = 1 for update;      -- single serialization point
  if st.status not in ('closed', 'closed_verification_failed') then
    raise exception 'restoration window cannot be opened while status is %', st.status using errcode = '55000';
  end if;
  select count(*) into v_fail from private.aios_restoration_log where event = 'open_denied' and at > clock_timestamp() - interval '15 minutes';
  if v_fail >= 5 then
    return jsonb_build_object('ok', false, 'reason', 'locked_out');
  end if;
  select * into c from private.aios_restoration_credentials where consumed_at is null and revoked_at is null for update;
  if not found or c.credential_hash <> extensions.crypt(p_credential, c.credential_hash) then
    perform private.aios_restoration_log_event('open_denied', jsonb_build_object('reason', 'credential_invalid'));
    return jsonb_build_object('ok', false, 'reason', 'credential_invalid');         -- returned (not raised) so the denial record commits
  end if;
  update private.aios_restoration_credentials set consumed_at = clock_timestamp(), consumed_by = session_user, consumed_window_id = v_win where id = c.id;
  update private.aios_restoration_state
     set generation = generation + 1, status = 'open', window_id = v_win, opened_at = clock_timestamp(), expires_at = clock_timestamp() + p_ttl,
         opened_by = session_user, reason = p_reason, closed_at = null, close_actor = null, updated_at = clock_timestamp()
   where id = 1 returning * into st;
  -- approved disable set only
  for g in select * from private.aios_guarded_triggers where restorable order by id loop
    execute format('alter table %I.%I disable trigger %I', g.schema_name, g.table_name, g.trigger_name);
    v_n := v_n + 1;
  end loop;
  perform private.aios_restoration_log_event('opened', jsonb_build_object('reason', p_reason, 'expires_at', st.expires_at, 'triggers_disabled', v_n));
  return jsonb_build_object('ok', true, 'window_id', st.window_id, 'generation', st.generation, 'expires_at', st.expires_at, 'triggers_disabled', v_n);
end $fn$;

-- 9. Close (exception-safe) ------------------------------------------------------------------------------------------------------
-- INVARIANT: a verification failure never rolls back successful trigger re-enablement. Each phase runs in its own sub-block;
-- failures are caught, recorded durably in the same (committing) transaction, and the function returns normally.
create or replace function private.aios_restoration_close_internal(p_generation bigint, p_actor text) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  st private.aios_restoration_state; g record; v_failed jsonb := '[]'::jsonb; v_drift jsonb; v_res jsonb; v_err text;
begin
  select * into st from private.aios_restoration_state where id = 1 for update;     -- re-lock; decision made while holding it
  if st.generation <> p_generation then
    return jsonb_build_object('ok', false, 'no_op', true, 'reason', 'stale_generation', 'current_generation', st.generation);
  end if;
  if st.status not in ('open', 'guard_reenable_failed') then
    return jsonb_build_object('ok', true, 'no_op', true, 'status', st.status);        -- idempotent
  end if;

  -- Phase 1: re-enable every guarded trigger; each in its own sub-block so partial progress persists
  perform set_config('lock_timeout', '10s', true);
  for g in select * from private.aios_guarded_triggers where restorable order by id loop
    begin
      if g.expected_enabled = 'A' then
        execute format('alter table %I.%I enable always trigger %I', g.schema_name, g.table_name, g.trigger_name);
      else
        execute format('alter table %I.%I enable trigger %I', g.schema_name, g.table_name, g.trigger_name);
      end if;
    exception when others then
      v_failed := v_failed || jsonb_build_object('trigger', g.trigger_name, 'sqlstate', sqlstate, 'error', sqlerrm);
    end;
  end loop;
  perform set_config('lock_timeout', '0', true);

  -- Phase 2: verify the ACTUAL catalog state (not our own bookkeeping)
  begin
    -- temporarily evaluate drift as 'closed' semantics by inspecting enablement directly
    select jsonb_agg(jsonb_build_object('trigger', gt.trigger_name, 'actual', tg.tgenabled::text))
      into v_drift
      from private.aios_guarded_triggers gt
      join pg_namespace ns on ns.nspname = gt.schema_name
      join pg_class c on c.relnamespace = ns.oid and c.relname = gt.table_name
      join pg_trigger tg on tg.tgrelid = c.oid and tg.tgname = gt.trigger_name and not tg.tgisinternal
     where gt.restorable and tg.tgenabled <> gt.expected_enabled;
    if v_drift is not null then v_failed := v_failed || jsonb_build_object('trigger', '*', 'error', 'catalog enablement mismatch', 'detail', v_drift); end if;
  exception when others then
    v_failed := v_failed || jsonb_build_object('trigger', '*', 'sqlstate', sqlstate, 'error', sqlerrm);
  end;

  if jsonb_array_length(v_failed) > 0 then
    update private.aios_restoration_state set status = 'guard_reenable_failed', last_failure = jsonb_build_object('phase', 'reenable', 'failures', v_failed, 'at', clock_timestamp()),
           updated_at = clock_timestamp() where id = 1;
    perform private.aios_restoration_log_event('guard_reenable_failed', jsonb_build_object('failures', v_failed, 'actor', p_actor));
    return jsonb_build_object('ok', false, 'status', 'guard_reenable_failed', 'failures', v_failed);
  end if;

  -- Phase 3: persist 'closed' BEFORE verification so a verifier exception cannot leave the window open
  update private.aios_restoration_state set status = 'closed', closed_at = clock_timestamp(), close_actor = p_actor, last_failure = null, updated_at = clock_timestamp() where id = 1;
  perform private.aios_restoration_log_event('closed', jsonb_build_object('actor', p_actor));

  -- Phase 4: canonical final verification (sub-block: a raise here rolls back only the verifier's own work)
  begin
    v_res := private.aios_final_verify(true, false);
    if coalesce((v_res ->> 'ok')::boolean, false) is not true then
      v_err := 'verification returned ok=false';
    end if;
  exception when others then
    v_res := null; v_err := sqlstate || ': ' || sqlerrm;
  end;
  if v_err is not null then
    update private.aios_restoration_state
       set status = 'closed_verification_failed', last_failure = jsonb_build_object('phase', 'verify', 'error', v_err, 'at', clock_timestamp()), updated_at = clock_timestamp() where id = 1;
    perform private.aios_restoration_log_event('verification_failed', jsonb_build_object('error', v_err, 'actor', p_actor,
            'overall', case when v_res is null then null else v_res ->> 'overall' end));
    return jsonb_build_object('ok', false, 'status', 'closed_verification_failed', 'triggers_reenabled', true, 'error', v_err);
  end if;
  return jsonb_build_object('ok', true, 'status', 'closed', 'verification', v_res ->> 'overall');
end $fn$;

create or replace function private.aios_restoration_close() returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare st private.aios_restoration_state;
begin
  perform private.aios_assert_restorer();
  select * into st from private.aios_restoration_state where id = 1 for update;
  return private.aios_restoration_close_internal(st.generation, 'owner:' || session_user);
end $fn$;

-- 10. Watchdog: read, decide and close under ONE row lock; the close is additionally bound to the inspected generation --------
create or replace function private.aios_restoration_watchdog() returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare st private.aios_restoration_state;
begin
  select * into st from private.aios_restoration_state where id = 1 for update;      -- lock BEFORE reading/deciding
  if st.status = 'open' and st.expires_at <= clock_timestamp() then
    return private.aios_restoration_close_internal(st.generation, 'watchdog');
  elsif st.status = 'guard_reenable_failed' then
    return private.aios_restoration_close_internal(st.generation, 'watchdog_retry');
  end if;
  return jsonb_build_object('ok', true, 'no_op', true, 'status', st.status);
end $fn$;

create or replace function private.aios_restoration_status() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare st private.aios_restoration_state;
begin
  perform private.aios_assert_restorer();
  select * into st from private.aios_restoration_state where id = 1;
  return to_jsonb(st) || jsonb_build_object('active_credential', exists (select 1 from private.aios_restoration_credentials where consumed_at is null and revoked_at is null));
end $fn$;

-- 11. Register the protected tables (initial baseline) -----------------------------------------------------------------------
-- Approved restoration disable set: ONLY the audit-store hash/immutability triggers. Execution-state triggers and (Part E)
-- anchor/verification-run triggers are monitored for drift but are never part of the disable set.
select private.aios_guard_register_table('public', 'aios_audit_events',
  array['trg_aios_audit_hash', 'trg_aios_audit_immutable_update', 'trg_aios_audit_immutable_delete', 'trg_aios_audit_no_truncate']);
select private.aios_guard_register_table('public', 'aios_tool_invocations');
select private.aios_guard_register_table('public', 'aios_missions');
select private.aios_guard_register_table('public', 'aios_tasks');
select private.aios_guard_register_table('public', 'aios_approvals');
select private.aios_guard_register_table('private', 'aios_restoration_log');

-- Owner-controlled re-baseline: ONLY when the window is closed and verification is not in a failed state.
create or replace function private.aios_guard_rebaseline(p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare st private.aios_restoration_state; v_before text; v_after text; r record; v_n int := 0;
begin
  perform private.aios_assert_restorer();
  if p_reason is null or length(btrim(p_reason)) < 10 then raise exception 'a reason of at least 10 characters is required' using errcode = '22023'; end if;
  select * into st from private.aios_restoration_state where id = 1 for update;
  if st.status <> 'closed' then raise exception 'rebaseline requires status closed (is %)', st.status using errcode = '55000'; end if;
  select encode(extensions.digest(coalesce(string_agg(schema_name || '.' || table_name || '.' || trigger_name || ':' || expected_trigger_fp || ':' || expected_function_fp, ',' order by id), ''), 'sha256'), 'hex')
    into v_before from private.aios_guarded_triggers;
  for r in select distinct schema_name, table_name from private.aios_guarded_triggers loop
    v_n := v_n + private.aios_guard_register_table(r.schema_name, r.table_name,
             coalesce((select array_agg(trigger_name::text) from private.aios_guarded_triggers x where x.schema_name = r.schema_name and x.table_name = r.table_name and x.restorable), '{}'));
  end loop;
  select encode(extensions.digest(coalesce(string_agg(schema_name || '.' || table_name || '.' || trigger_name || ':' || expected_trigger_fp || ':' || expected_function_fp, ',' order by id), ''), 'sha256'), 'hex')
    into v_after from private.aios_guarded_triggers;
  perform private.aios_restoration_log_event('registry_rebaselined', jsonb_build_object('reason', p_reason, 'before', v_before, 'after', v_after));
  return jsonb_build_object('ok', true, 'registry_before', v_before, 'registry_after', v_after, 'triggers', v_n);
end $fn$;

-- 12. Schedule inventory + idempotent cron registration (reuses the existing pg_cron mechanism) ------------------------------------
select cron.schedule('aios-restoration-watchdog', '*/5 * * * *', $$select private.aios_restoration_watchdog()$$);

create or replace function private.aios_schedule_check() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare v jsonb := '[]'::jsonb; e record; j record;
begin
  for e in select * from (values
      ('aios-restoration-watchdog', '*/5 * * * *', 'select private.aios_restoration_watchdog()'),
      ('aios-audit-verify-hourly',  '7 * * * *',   'select private.aios_scheduled_verify()'),
      ('aios-reap-stale-tasks',     '*/5 * * * *', null),
      ('aios-expire-stale-approvals','*/5 * * * *', null)) as x(jobname, schedule, command) loop
    if (select count(*) from cron.job where jobname = e.jobname) > 1 then
      v := v || jsonb_build_object('kind', 'duplicate_job', 'job', e.jobname);   -- cron.job is keyed by (jobname, username): another user re-scheduling creates a twin
    end if;
    select * into j from cron.job where jobname = e.jobname order by jobid limit 1;
    if not found then v := v || jsonb_build_object('kind', 'job_missing', 'job', e.jobname);
    else
      if not j.active then v := v || jsonb_build_object('kind', 'job_inactive', 'job', e.jobname); end if;
      if j.schedule <> e.schedule then v := v || jsonb_build_object('kind', 'schedule_changed', 'job', e.jobname, 'actual', j.schedule); end if;
      if e.command is not null and btrim(j.command) <> e.command then v := v || jsonb_build_object('kind', 'command_changed', 'job', e.jobname); end if;
    end if;
  end loop;
  return jsonb_build_object('problem_count', jsonb_array_length(v), 'problems', v,
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object('job', jobname, 'schedule', schedule, 'active', active, 'username', username) order by jobname), '[]'::jsonb) from cron.job where jobname like 'aios-%'));
end $fn$;
revoke all on function private.aios_schedule_check() from public, anon, authenticated, service_role;

-- 13. EXECUTE grants: aios_restorer only (owner keeps implicit EXECUTE; pg_cron runs as owner) ---------------------------------
revoke all on function private.aios_restoration_install_credential(text), private.aios_restoration_rotate_credential(text, text),
  private.aios_restoration_open(text, text, interval), private.aios_restoration_close_internal(bigint, text),
  private.aios_restoration_close(), private.aios_restoration_watchdog(), private.aios_restoration_status(), private.aios_guard_rebaseline(text)
  from public, anon, authenticated, service_role;
grant execute on function private.aios_restoration_install_credential(text), private.aios_restoration_rotate_credential(text, text),
  private.aios_restoration_open(text, text, interval), private.aios_restoration_close(), private.aios_restoration_status(), private.aios_guard_rebaseline(text)
  to aios_restorer;
-- close_internal and the watchdog are owner/cron-only (no role, including aios_restorer, may call them directly)
