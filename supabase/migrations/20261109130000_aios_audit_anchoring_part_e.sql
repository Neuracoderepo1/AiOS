-- PART E: independently anchored audit verification.
--
-- TRUST MODEL (docs/security/AUDIT-INTEGRITY.md): a database cannot certify its own history against a privileged DBA.
--   * This migration provides (a) a canonical, historical-algorithm-exact audit hash, (b) append-only anchor and verification-run
--     records, (c) bounded canonical export, (d) ONE final verifier that combines chain, anchor coverage/freshness, trigger drift,
--     restoration state and schedules.
--   * The database CANNOT authenticate an RFC3161 token or Git commit. Anchors are accepted only if their evidence is structurally valid and
--     BOUND to the exact (organization, event_count, head id, head hash, head timestamp) via the checkpoint digest. Cryptographic
--     authenticity is established OUTSIDE the database (tools/audit-verify + .github/workflows/audit-verify.yml); an external
--     verification record written by the service role is reported as "service_role_asserted", never as proof.
--   * Live RFC3161 anchoring is EXTERNAL_DEPENDENCY_BLOCKED until a real TSA and trust roots are configured.
--
-- HISTORICAL ALGORITHM (preserved, defined by private.aios_audit_append() in 20260825123422):
--   payload = jsonb_build_object(id, organization_id, actor_user_id, actor_type, agent_id, mission_id, task_id, invocation_id, event_type,
--             previous_state, new_state, tool_name, risk_level, arguments_hash, result_hash, approval_id, created_at, metadata,
--             previous_event_hash)::text || previous_event_hash            -- previous_event_hash is deliberately included TWICE
--   event_hash = hex(sha256(payload));  previous_event_hash = prior event's hash or 'GENESIS:'||organization_id;  order = (created_at, id);
--   created_at is advanced by 1 microsecond on collision. FINDING: jsonb timestamptz text depends on the session TimeZone, so the
--   canonical functions pin UTC; histories appended under a non-UTC session TimeZone would verify as chain_mismatch (fail-closed).

-- 1. Policy ---------------------------------------------------------------------------------------------------------------------
create table if not exists private.aios_audit_anchor_policy (
  id                         int primary key default 1 check (id = 1),
  max_unanchored_age         interval not null default interval '2 hours' check (max_unanchored_age >= interval '10 minutes' and max_unanchored_age <= interval '24 hours'),
  max_unanchored_events      bigint check (max_unanchored_events is null or max_unanchored_events > 0),
  external_verification_max_age interval not null default interval '2 hours' check (external_verification_max_age >= interval '10 minutes' and external_verification_max_age <= interval '24 hours'),
  updated_at                 timestamptz not null default clock_timestamp(),
  updated_by                 name not null default session_user
);
insert into private.aios_audit_anchor_policy (id) values (1) on conflict (id) do nothing;

-- 2. Append-only anchor + verification-run tables ----------------------------------------------------------------------------------
create table if not exists private.aios_audit_anchors (
  id               bigint generated always as identity primary key,
  organization_id  uuid not null,
  event_count      bigint not null check (event_count > 0),
  head_event_id    uuid not null,
  head_hash        text not null check (head_hash ~ '^[0-9a-f]{64}$'),
  head_at          timestamptz not null,
  algorithm_version text not null default 'aios-audit-sha256-v1',
  evidence_type    text not null check (evidence_type in ('rfc3161', 'git')),
  checkpoint_sha256 text not null check (checkpoint_sha256 ~ '^[0-9a-f]{64}$'),
  artifact_sha256  text not null check (artifact_sha256 ~ '^[0-9a-f]{64}$'),
  artifact_ref     text not null check (length(artifact_ref) between 1 and 2048),
  evidence         jsonb not null default '{}'::jsonb,
  recorded_at      timestamptz not null default clock_timestamp(),
  recorded_by      name not null default session_user,
  unique (organization_id, event_count, evidence_type, artifact_sha256)
);
create index if not exists aios_audit_anchors_org_count on private.aios_audit_anchors (organization_id, event_count desc);

create table if not exists private.aios_audit_verification_runs (
  id               bigint generated always as identity primary key,
  organization_id  uuid,                                   -- null = global run
  kind             text not null check (kind in ('internal', 'scheduled', 'external')),
  status           text not null,
  ok               boolean not null,
  anchor_id        bigint references private.aios_audit_anchors (id),
  event_count      bigint,
  head_hash        text,
  report_sha256    text check (report_sha256 is null or report_sha256 ~ '^[0-9a-f]{64}$'),
  details          jsonb not null default '{}'::jsonb,
  finished_at      timestamptz not null default clock_timestamp(),
  recorded_by      name not null default session_user
);
create index if not exists aios_audit_runs_org_kind on private.aios_audit_verification_runs (organization_id, kind, finished_at desc);

alter table private.aios_audit_anchor_policy      enable row level security;
alter table private.aios_audit_anchors            enable row level security;
alter table private.aios_audit_verification_runs  enable row level security;
revoke all on private.aios_audit_anchor_policy, private.aios_audit_anchors, private.aios_audit_verification_runs
  from public, anon, authenticated, service_role, aios_restorer;

do $$ declare t text; begin
  foreach t in array array['aios_audit_anchors', 'aios_audit_verification_runs'] loop
    execute format('drop trigger if exists trg_%s_no_mutate on private.%I', t, t);
    execute format('create trigger trg_%s_no_mutate before update or delete on private.%I for each row execute function private.aios_append_only_guard()', t, t);
    execute format('drop trigger if exists trg_%s_no_truncate on private.%I', t, t);
    execute format('create trigger trg_%s_no_truncate before truncate on private.%I for each statement execute function private.aios_append_only_guard()', t, t);
    execute format('alter table private.%I enable always trigger trg_%s_no_mutate', t, t);
    execute format('alter table private.%I enable always trigger trg_%s_no_truncate', t, t);
  end loop;
end $$;

-- 3. Canonical payload / hash (the ONLY implementation used by verification, export and anchoring) -------------------------------------
create or replace function private.aios_audit_canonical_payload(p public.aios_audit_events, p_prev text) returns text
language sql stable set search_path = '' set timezone = 'UTC' as $fn$
  select jsonb_build_object('id', p.id, 'organization_id', p.organization_id, 'actor_user_id', p.actor_user_id, 'actor_type', p.actor_type,
    'agent_id', p.agent_id, 'mission_id', p.mission_id, 'task_id', p.task_id, 'invocation_id', p.invocation_id, 'event_type', p.event_type,
    'previous_state', p.previous_state, 'new_state', p.new_state, 'tool_name', p.tool_name, 'risk_level', p.risk_level,
    'arguments_hash', p.arguments_hash, 'result_hash', p.result_hash, 'approval_id', p.approval_id, 'created_at', p.created_at,
    'metadata', p.metadata, 'previous_event_hash', p_prev)::text || p_prev
$fn$;

create or replace function private.aios_audit_canonical_hash(p public.aios_audit_events, p_prev text) returns text
language sql stable set search_path = '' set timezone = 'UTC' as $fn$
  select encode(extensions.digest(private.aios_audit_canonical_payload(p, p_prev), 'sha256'), 'hex')
$fn$;

create or replace function private.aios_audit_checkpoint_text(p_org uuid, p_count bigint, p_head_id uuid, p_head_hash text, p_head_at timestamptz) returns text
language sql immutable set search_path = '' as $fn$
  select 'aios-audit-checkpoint-v1' || E'\n' || p_org::text || E'\n' || p_count::text || E'\n' || p_head_id::text || E'\n' || p_head_hash || E'\n' ||
         to_char(p_head_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$fn$;

create or replace function private.aios_audit_checkpoint_digest(p_org uuid, p_count bigint, p_head_id uuid, p_head_hash text, p_head_at timestamptz) returns text
language sql immutable set search_path = '' as $fn$
  select encode(extensions.digest(private.aios_audit_checkpoint_text(p_org, p_count, p_head_id, p_head_hash, p_head_at), 'sha256'), 'hex')
$fn$;

-- 4. Chain verification (canonical) -----------------------------------------------------------------------------------------------------
create or replace function private.aios_audit_verify_chain_v2(p_org uuid, p_from_count bigint default 0, p_from_prev text default null, p_to_count bigint default null) returns jsonb
language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $fn$
declare
  r public.aios_audit_events; v_prev text; v_n bigint := p_from_count; v_hash text; v_last public.aios_audit_events;
begin
  if p_from_count < 0 then raise exception 'p_from_count must be >= 0' using errcode = '22023'; end if;
  v_prev := case when p_from_count = 0 then 'GENESIS:' || p_org::text else p_from_prev end;
  if v_prev is null then raise exception 'p_from_prev is required when p_from_count > 0' using errcode = '22023'; end if;
  for r in select * from public.aios_audit_events where organization_id = p_org order by created_at, id offset p_from_count loop
    exit when p_to_count is not null and v_n >= p_to_count;
    v_n := v_n + 1;
    v_hash := private.aios_audit_canonical_hash(r, v_prev);
    if r.previous_event_hash is distinct from v_prev or r.event_hash is distinct from v_hash then
      return jsonb_build_object('valid', false, 'reason', case when r.previous_event_hash is distinct from v_prev then 'previous_hash_mismatch' else 'event_hash_mismatch' end,
        'broken_at_count', v_n, 'broken_event_id', r.id, 'expected_hash', v_hash, 'actual_hash', r.event_hash, 'events_checked', v_n - p_from_count);
    end if;
    v_prev := r.event_hash; v_last := r;
  end loop;
  return jsonb_build_object('valid', true, 'events_checked', v_n - p_from_count, 'head_count', v_n,
    'head_id', v_last.id, 'head_hash', case when v_n = p_from_count then p_from_prev else v_last.event_hash end, 'head_at', v_last.created_at);
end $fn$;

-- 5. Bounded, stable export ---------------------------------------------------------------------------------------------------------------
create or replace function private.aios_audit_chain_export(p_org uuid, p_after_count bigint default 0, p_limit int default 500) returns jsonb
language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $fn$
declare v jsonb;
begin
  if p_org is null then raise exception 'organization is required' using errcode = '22023'; end if;
  if p_after_count is null or p_after_count < 0 then raise exception 'p_after_count must be >= 0' using errcode = '22023'; end if;
  if p_limit is null or p_limit < 1 or p_limit > 1000 then raise exception 'p_limit must be between 1 and 1000' using errcode = '22023'; end if;
  -- ONE statement => one snapshot for head and page. Consumers compare total_events/head_hash across pages to detect snapshot drift
  -- (concurrent appends only extend the tail; any other change is a chain/anchor violation).
  with head as (
    select count(*) as n, (array_agg(id order by created_at desc, id desc))[1] as head_id,
           (array_agg(event_hash order by created_at desc, id desc))[1] as head_hash,
           (array_agg(created_at order by created_at desc, id desc))[1] as head_at
    from public.aios_audit_events where organization_id = p_org),
  page as (
    select e.*, p_after_count + row_number() over (order by e.created_at, e.id) as seq
    from (select * from public.aios_audit_events where organization_id = p_org order by created_at, id offset p_after_count limit p_limit) e)
  select jsonb_build_object('algorithm_version', 'aios-audit-sha256-v1', 'organization_id', p_org, 'after_count', p_after_count, 'limit', p_limit,
      'total_events', (select n from head), 'head_id', (select head_id from head), 'head_hash', (select head_hash from head), 'head_at', (select head_at from head),
      'returned', (select count(*) from page), 'has_more', p_after_count + (select count(*) from page) < (select n from head),
      'events', coalesce((select jsonb_agg(jsonb_build_object('seq', seq, 'id', id, 'organization_id', organization_id, 'actor_user_id', actor_user_id, 'actor_type', actor_type,
         'agent_id', agent_id, 'mission_id', mission_id, 'task_id', task_id, 'invocation_id', invocation_id, 'event_type', event_type, 'previous_state', previous_state,
         'new_state', new_state, 'tool_name', tool_name, 'risk_level', risk_level, 'arguments_hash', arguments_hash, 'result_hash', result_hash, 'approval_id', approval_id,
         'created_at', created_at, 'metadata', metadata, 'previous_event_hash', previous_event_hash, 'event_hash', event_hash) order by seq) from page), '[]'::jsonb))
  into v;
  return v;
end $fn$;

create or replace function private.aios_audit_heads() returns jsonb
language sql stable security definer set search_path = '' set timezone = 'UTC' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object('organization_id', organization_id, 'event_count', n, 'head_id', head_id, 'head_hash', head_hash, 'head_at', head_at) order by organization_id), '[]'::jsonb)
  from (select organization_id, count(*) as n, (array_agg(id order by created_at desc, id desc))[1] as head_id,
               (array_agg(event_hash order by created_at desc, id desc))[1] as head_hash, (array_agg(created_at order by created_at desc, id desc))[1] as head_at
        from public.aios_audit_events group by organization_id) h
$fn$;

-- 6. Anchor recording ---------------------------------------------------------------------------------------------------------------------
create or replace function private.aios_audit_record_anchor(p_org uuid, p_event_count bigint, p_head_event_id uuid, p_head_hash text, p_head_at timestamptz,
  p_evidence_type text, p_artifact_sha256 text, p_artifact_ref text, p_evidence jsonb) returns jsonb
language plpgsql security definer set search_path = '' set timezone = 'UTC' as $fn$
declare
  v_ev public.aios_audit_events; v_total bigint; v_last private.aios_audit_anchors; v_chain jsonb; v_digest text; v_existing bigint; v_id bigint; v_prev_hash text;
begin
  if p_org is null or p_event_count is null or p_event_count < 1 or p_head_event_id is null or p_head_hash is null or p_head_at is null
     or p_evidence_type is null or p_artifact_sha256 is null or p_artifact_ref is null then
    raise exception 'all anchor parameters are required' using errcode = '22023';
  end if;
  if p_head_hash !~ '^[0-9a-f]{64}$' or p_artifact_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'hashes must be 64 lowercase hex characters' using errcode = '22023'; end if;
  if p_evidence_type not in ('rfc3161', 'git') then raise exception 'unsupported evidence type %', p_evidence_type using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('aios-anchor:' || p_org::text, 0));           -- serialize anchor recording per org (not the audit-append lock)

  select count(*) into v_total from public.aios_audit_events where organization_id = p_org;
  if p_event_count > v_total then raise exception 'event_count % does not exist (org has % events)', p_event_count, v_total using errcode = '22023'; end if;
  select * into v_ev from public.aios_audit_events where organization_id = p_org order by created_at, id offset p_event_count - 1 limit 1;
  if v_ev.id is distinct from p_head_event_id then raise exception 'head_event_id does not match the event at position %', p_event_count using errcode = '22023'; end if;
  if v_ev.event_hash is distinct from p_head_hash then raise exception 'head_hash does not match the event at position %', p_event_count using errcode = '22023'; end if;
  if v_ev.created_at is distinct from p_head_at then raise exception 'head_at does not match the recorded timestamp of the event at position % (got %, actual %)', p_event_count, p_head_at, v_ev.created_at using errcode = '22023'; end if;

  select * into v_last from private.aios_audit_anchors where organization_id = p_org order by event_count desc, id desc limit 1;
  if found then
    if p_event_count < v_last.event_count then raise exception 'anchor regression: % < latest accepted %', p_event_count, v_last.event_count using errcode = '22023'; end if;
    if p_event_count = v_last.event_count and p_head_hash <> v_last.head_hash then raise exception 'anchor conflict at event_count %', p_event_count using errcode = '22023'; end if;
  end if;

  -- chain must be valid from the last accepted anchor (or genesis) through the anchored position
  v_chain := private.aios_audit_verify_chain_v2(p_org, coalesce(v_last.event_count, 0), v_last.head_hash, p_event_count);
  if (v_chain ->> 'valid')::boolean is not true then raise exception 'audit chain invalid before anchored position: %', v_chain using errcode = '22023'; end if;

  -- bind the external evidence to the exact checkpoint
  v_digest := private.aios_audit_checkpoint_digest(p_org, p_event_count, p_head_event_id, p_head_hash, p_head_at);
  if p_evidence_type = 'rfc3161' then
    if coalesce(p_evidence ->> 'message_imprint', '') <> v_digest then raise exception 'rfc3161 message_imprint does not equal the checkpoint digest' using errcode = '22023'; end if;
    if coalesce(p_evidence ->> 'token_sha256', '') <> p_artifact_sha256 or coalesce(p_evidence ->> 'tsa_name', '') = '' or coalesce(p_evidence ->> 'gen_time', '') = '' then
      raise exception 'rfc3161 evidence requires token_sha256 (= artifact), tsa_name and gen_time' using errcode = '22023'; end if;
  else
    if coalesce(p_evidence ->> 'manifest_sha256', '') <> v_digest then raise exception 'git manifest_sha256 does not equal the checkpoint digest' using errcode = '22023'; end if;
    if coalesce(p_evidence ->> 'commit', '') !~ '^[0-9a-f]{40}$' or coalesce(p_evidence ->> 'repository', '') = '' or coalesce(p_evidence ->> 'manifest_path', '') = '' then
      raise exception 'git evidence requires repository, commit (40 hex) and manifest_path' using errcode = '22023'; end if;
  end if;
  if coalesce(p_evidence ->> 'verified_by', '') = '' then raise exception 'evidence must name the external verifier (verified_by)' using errcode = '22023'; end if;

  select id into v_existing from private.aios_audit_anchors where organization_id = p_org and event_count = p_event_count and evidence_type = p_evidence_type and artifact_sha256 = p_artifact_sha256;
  if v_existing is not null then return jsonb_build_object('ok', true, 'anchor_id', v_existing, 'idempotent', true); end if;
  insert into private.aios_audit_anchors (organization_id, event_count, head_event_id, head_hash, head_at, evidence_type, checkpoint_sha256, artifact_sha256, artifact_ref, evidence)
  values (p_org, p_event_count, p_head_event_id, p_head_hash, p_head_at, p_evidence_type, v_digest, p_artifact_sha256, p_artifact_ref, p_evidence) returning id into v_id;
  return jsonb_build_object('ok', true, 'anchor_id', v_id, 'idempotent', false, 'checkpoint_sha256', v_digest, 'authenticity', 'NOT_VERIFIED_BY_DATABASE');
end $fn$;

create or replace function private.aios_audit_record_external_verification(p_org uuid, p_anchor_id bigint, p_event_count bigint, p_head_hash text, p_report_sha256 text, p_ok boolean, p_details jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare a private.aios_audit_anchors; v_id bigint;
begin
  select * into a from private.aios_audit_anchors where id = p_anchor_id and organization_id = p_org;
  if not found then raise exception 'unknown anchor % for organization', p_anchor_id using errcode = '22023'; end if;
  if a.event_count <> p_event_count or a.head_hash <> p_head_hash then raise exception 'report does not match the anchor (count/head)' using errcode = '22023'; end if;
  if p_report_sha256 is null or p_report_sha256 !~ '^[0-9a-f]{64}$' or p_ok is null then raise exception 'report_sha256 and ok are required' using errcode = '22023'; end if;
  insert into private.aios_audit_verification_runs (organization_id, kind, status, ok, anchor_id, event_count, head_hash, report_sha256, details)
  values (p_org, 'external', case when p_ok then 'external_verified' else 'external_verification_failed' end, p_ok, a.id, a.event_count, a.head_hash, p_report_sha256,
          coalesce(p_details, '{}'::jsonb) || jsonb_build_object('trust', 'service_role_asserted')) returning id into v_id;
  return jsonb_build_object('ok', true, 'run_id', v_id);
end $fn$;

create or replace function private.aios_audit_anchors_list(p_org uuid) returns jsonb
language sql stable security definer set search_path = '' set timezone = 'UTC' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'organization_id', organization_id, 'event_count', event_count, 'head_event_id', head_event_id, 'head_hash', head_hash,
    'head_at', to_jsonb(head_at) #>> '{}', 'evidence_type', evidence_type, 'checkpoint_sha256', checkpoint_sha256, 'artifact_sha256', artifact_sha256,
    'artifact_ref', artifact_ref, 'evidence', evidence, 'recorded_at', recorded_at) order by event_count, id), '[]'::jsonb)
  from private.aios_audit_anchors where organization_id = p_org
$fn$;

-- 7. Owner-controlled policy -----------------------------------------------------------------------------------------------------------------
create or replace function private.aios_audit_policy_set(p_max_unanchored_age interval, p_external_max_age interval, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
begin
  perform private.aios_assert_restorer();
  if p_reason is null or length(btrim(p_reason)) < 10 then raise exception 'a reason of at least 10 characters is required' using errcode = '22023'; end if;
  update private.aios_audit_anchor_policy set max_unanchored_age = p_max_unanchored_age, external_verification_max_age = p_external_max_age, updated_at = clock_timestamp(), updated_by = session_user where id = 1;
  perform private.aios_restoration_log_event('policy_changed', jsonb_build_object('max_unanchored_age', p_max_unanchored_age, 'external_max_age', p_external_max_age, 'reason', p_reason));
  return jsonb_build_object('ok', true);
end $fn$;

-- 8. Function pins (verifier cannot be weakened silently) ------------------------------------------------------------------------------------
create table if not exists private.aios_function_pins (function_signature text primary key, fingerprint text not null, pinned_at timestamptz not null default clock_timestamp());
alter table private.aios_function_pins enable row level security;
revoke all on private.aios_function_pins from public, anon, authenticated, service_role, aios_restorer;

-- 9. THE final verifier ---------------------------------------------------------------------------------------------------------------------------
-- Statuses per organization:
--   verified | valid_unanchored | stale_anchor | anchor_mismatch | chain_mismatch | truncated_history | anchored_unattested |
--   external_verification_failed | anchor_untrusted_fixture | verification_error
-- overall: VERIFIED (ok=true) | INCOMPLETE (no failure, but a required control is not satisfied) | FAIL
create or replace function private.aios_final_verify(p_record boolean default true, p_allow_test_fixtures boolean default false, p_kind text default 'internal') returns jsonb
language plpgsql security definer set search_path = '' set timezone = 'UTC' as $fn$
declare
  pol private.aios_audit_anchor_policy; st private.aios_restoration_state; o record; v_orgs jsonb := '[]'::jsonb; v_status text; v_detail jsonb;
  v_chain jsonb; v_head_n bigint; v_head_id uuid; v_head_hash text; v_head_at timestamptz; la private.aios_audit_anchors; v_bad record; v_tail bigint; v_oldest timestamptz;
  v_ext private.aios_audit_verification_runs; v_ext_ok timestamptz; v_drift jsonb; v_sched jsonb; v_failed boolean := false; v_incomplete boolean := false;
  v_overall text; v_orgs_verified int := 0; v_orgs_total int := 0; v_controls jsonb; v_restoration_ok boolean; v_anchor_ok boolean; v_res jsonb; v_started timestamptz := clock_timestamp();
begin
  if p_kind not in ('internal', 'scheduled') then raise exception 'invalid kind' using errcode = '22023'; end if;
  select * into pol from private.aios_audit_anchor_policy where id = 1;
  select * into st from private.aios_restoration_state where id = 1;

  for o in select organization_id from (select organization_id from public.aios_audit_events union select organization_id from private.aios_audit_anchors) x group by organization_id order by organization_id loop
    v_orgs_total := v_orgs_total + 1; v_status := null; v_detail := '{}'::jsonb;
    begin
      select count(*), (array_agg(id order by created_at desc, id desc))[1], (array_agg(event_hash order by created_at desc, id desc))[1], (array_agg(created_at order by created_at desc, id desc))[1]
        into v_head_n, v_head_id, v_head_hash, v_head_at from public.aios_audit_events where organization_id = o.organization_id;
      select * into la from private.aios_audit_anchors where organization_id = o.organization_id order by event_count desc, id desc limit 1;

      if v_head_n = 0 then
        v_status := 'truncated_history'; v_detail := jsonb_build_object('reason', 'anchors exist but the organization has no audit events');
      else
        v_chain := private.aios_audit_verify_chain_v2(o.organization_id);
        if (v_chain ->> 'valid')::boolean is not true then
          v_status := 'chain_mismatch'; v_detail := v_chain;
        end if;
      end if;

      -- every accepted anchor must still match the event at its position (detects altered-and-resealed or truncated history)
      if v_status is null and la.id is not null then
        select a.id as anchor_id, a.event_count, (n.rn is null) as beyond_head,
               (n.rn is not null and (n.id <> a.head_event_id or n.event_hash <> a.head_hash or n.created_at <> a.head_at)) as mismatch into v_bad
          from private.aios_audit_anchors a
          left join (select id, event_hash, created_at, row_number() over (order by created_at, id) as rn from public.aios_audit_events where organization_id = o.organization_id) n on n.rn = a.event_count
         where a.organization_id = o.organization_id and (n.rn is null or n.id <> a.head_event_id or n.event_hash <> a.head_hash or n.created_at <> a.head_at)
         order by a.event_count limit 1;
        if found then
          v_status := case when v_bad.beyond_head then 'truncated_history' else 'anchor_mismatch' end;
          v_detail := jsonb_build_object('anchor_id', v_bad.anchor_id, 'anchor_event_count', v_bad.event_count);
        end if;
      end if;

      if v_status is null then
        if la.id is null then
          v_status := 'valid_unanchored';
        elsif coalesce(la.evidence ->> 'class', '') = 'TEST_FIXTURE' and not p_allow_test_fixtures then
          v_status := 'anchor_untrusted_fixture';
        else
          v_tail := v_head_n - la.event_count;
          if v_tail > 0 then
            select created_at into v_oldest from public.aios_audit_events where organization_id = o.organization_id order by created_at, id offset la.event_count limit 1;
            v_detail := jsonb_build_object('unanchored_tail_events', v_tail, 'oldest_unanchored_age_seconds', extract(epoch from clock_timestamp() - v_oldest));
            if clock_timestamp() - v_oldest > pol.max_unanchored_age or (pol.max_unanchored_events is not null and v_tail > pol.max_unanchored_events) then
              v_status := 'stale_anchor';
            end if;
          end if;
          if v_status is null then
            select * into v_ext from private.aios_audit_verification_runs
              where organization_id = o.organization_id and kind = 'external' and anchor_id = la.id order by finished_at desc, id desc limit 1;
            if not found then v_status := 'anchored_unattested';
            elsif not v_ext.ok then v_status := 'external_verification_failed';
            elsif clock_timestamp() - v_ext.finished_at > pol.external_verification_max_age then v_status := 'anchored_unattested'; v_detail := v_detail || jsonb_build_object('external_verification', 'stale');
            else v_status := 'verified'; end if;
          end if;
        end if;
      end if;
    exception when others then
      v_status := 'verification_error'; v_detail := jsonb_build_object('sqlstate', sqlstate, 'error', sqlerrm);
    end;

    select max(finished_at) into v_ext_ok from private.aios_audit_verification_runs where organization_id = o.organization_id and kind = 'external' and ok;
    if v_status = 'verified' then v_orgs_verified := v_orgs_verified + 1;
    elsif v_status in ('chain_mismatch', 'anchor_mismatch', 'truncated_history', 'external_verification_failed', 'verification_error') then v_failed := true;
    else v_incomplete := true; end if;
    v_orgs := v_orgs || jsonb_build_object('organization_id', o.organization_id, 'status', v_status, 'ok', v_status = 'verified', 'event_count', v_head_n, 'head_hash', v_head_hash,
      'latest_anchor_id', la.id, 'latest_anchor_event_count', la.event_count, 'last_anchor_recorded_at', la.recorded_at, 'last_external_ok_at', v_ext_ok, 'detail', v_detail);
  end loop;

  v_drift := private.aios_guard_drift();
  v_sched := private.aios_schedule_check();
  v_restoration_ok := st.status = 'closed';
  v_anchor_ok := v_orgs_verified = v_orgs_total;
  if (v_drift ->> 'drift_count')::int > 0 and st.status in ('closed', 'closed_verification_failed') then v_failed := true; end if;
  if (v_drift ->> 'drift_count')::int > 0 and st.status in ('open', 'guard_reenable_failed') then v_incomplete := true; end if;
  if (v_sched ->> 'problem_count')::int > 0 then v_failed := true; end if;
  if st.status in ('guard_reenable_failed', 'closed_verification_failed') then v_failed := true;
  elsif st.status = 'open' then v_incomplete := true; end if;

  v_overall := case when v_failed then 'FAIL' when v_incomplete then 'INCOMPLETE' else 'VERIFIED' end;
  v_controls := jsonb_build_object('audit_chain_and_anchors', v_anchor_ok, 'trigger_drift', (v_drift ->> 'drift_count')::int = 0, 'restoration_closed', v_restoration_ok, 'schedules', (v_sched ->> 'problem_count')::int = 0);
  v_res := jsonb_build_object('ok', v_overall = 'VERIFIED', 'overall', v_overall, 'partial', false, 'organizations_total', v_orgs_total, 'organizations_verified', v_orgs_verified,
    'organizations', v_orgs, 'controls', v_controls, 'guard_drift', v_drift, 'schedules', v_sched, 'restoration', jsonb_build_object('status', st.status, 'generation', st.generation, 'window_id', st.window_id),
    'policy', jsonb_build_object('max_unanchored_age', pol.max_unanchored_age::text, 'max_unanchored_events', pol.max_unanchored_events, 'external_verification_max_age', pol.external_verification_max_age::text),
    'external_attestation_trust', 'service_role_asserted', 'certification_grade', false, 'algorithm_version', 'aios-audit-sha256-v1',
    'verifier_fingerprint', private.aios_function_fingerprint('private.aios_final_verify(boolean,boolean,text)'::regprocedure), 'verified_at', clock_timestamp());

  if p_record then
    insert into private.aios_audit_verification_runs (organization_id, kind, status, ok, details, finished_at)
      select (x ->> 'organization_id')::uuid, p_kind, x ->> 'status', (x ->> 'ok')::boolean, x -> 'detail', clock_timestamp() from jsonb_array_elements(v_orgs) x;
    insert into private.aios_audit_verification_runs (organization_id, kind, status, ok, details, finished_at)
      values (null, p_kind, lower(v_overall), v_overall = 'VERIFIED', jsonb_build_object('controls', v_controls, 'started_at', v_started, 'drift_count', v_drift -> 'drift_count',
              'schedule_problems', v_sched -> 'problem_count', 'restoration_status', st.status), clock_timestamp());
  end if;
  return v_res;
end $fn$;

-- 10. Scheduled verification (never raises; never converts an outage into success) ---------------------------------------------------------
create or replace function private.aios_scheduled_verify() returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_res jsonb; v_mismatch jsonb; st private.aios_restoration_state; v_other_ok boolean;
begin
  select coalesce(jsonb_agg(jsonb_build_object('function', p.function_signature)), '[]'::jsonb) into v_mismatch
    from private.aios_function_pins p
   where private.aios_function_fingerprint(p.function_signature::regprocedure) is distinct from p.fingerprint;
  if v_mismatch <> '[]'::jsonb then
    insert into private.aios_audit_verification_runs (kind, status, ok, details) values ('scheduled', 'verifier_pin_mismatch', false, jsonb_build_object('mismatched', v_mismatch));
    return jsonb_build_object('ok', false, 'overall', 'FAIL', 'reason', 'verifier_pin_mismatch', 'mismatched', v_mismatch);
  end if;
  begin
    v_res := private.aios_final_verify(true, false, 'scheduled');
  exception when others then
    insert into private.aios_audit_verification_runs (kind, status, ok, details) values ('scheduled', 'verification_error', false, jsonb_build_object('sqlstate', sqlstate, 'error', sqlerrm));
    return jsonb_build_object('ok', false, 'overall', 'FAIL', 'reason', 'verification_error', 'error', sqlerrm);
  end;
  -- recovery from a failed closing verification: every control except the restoration state itself must pass
  select * into st from private.aios_restoration_state where id = 1 for update;
  if st.status = 'closed_verification_failed' then
    v_other_ok := (v_res -> 'controls' ->> 'audit_chain_and_anchors')::boolean and (v_res -> 'controls' ->> 'trigger_drift')::boolean and (v_res -> 'controls' ->> 'schedules')::boolean;
    if v_other_ok then
      update private.aios_restoration_state set status = 'closed', last_failure = null, updated_at = clock_timestamp() where id = 1;
      perform private.aios_restoration_log_event('verification_recovered', jsonb_build_object('by', 'scheduled_verify'));
      v_res := private.aios_final_verify(true, false, 'scheduled');
    end if;
  end if;
  return v_res;
end $fn$;

-- 11. Pins, registry, schedule, grants -------------------------------------------------------------------------------------------------------------
insert into private.aios_function_pins (function_signature, fingerprint)
select s, private.aios_function_fingerprint(s::regprocedure) from unnest(array[
  'private.aios_final_verify(boolean,boolean,text)', 'private.aios_audit_canonical_payload(public.aios_audit_events,text)',
  'private.aios_audit_canonical_hash(public.aios_audit_events,text)', 'private.aios_audit_verify_chain_v2(uuid,bigint,text,bigint)',
  'private.aios_audit_record_anchor(uuid,bigint,uuid,text,timestamp with time zone,text,text,text,jsonb)', 'private.aios_guard_drift()', 'private.aios_audit_checkpoint_text(uuid,bigint,uuid,text,timestamp with time zone)']) s
on conflict (function_signature) do update set fingerprint = excluded.fingerprint, pinned_at = clock_timestamp();

select private.aios_guard_register_table('private', 'aios_audit_anchors');
select private.aios_guard_register_table('private', 'aios_audit_verification_runs');

select cron.schedule('aios-audit-verify-hourly', '7 * * * *', $$select private.aios_scheduled_verify()$$);

revoke all on function private.aios_audit_canonical_payload(public.aios_audit_events, text), private.aios_audit_canonical_hash(public.aios_audit_events, text),
  private.aios_audit_checkpoint_text(uuid, bigint, uuid, text, timestamptz), private.aios_audit_checkpoint_digest(uuid, bigint, uuid, text, timestamptz),
  private.aios_audit_verify_chain_v2(uuid, bigint, text, bigint), private.aios_audit_chain_export(uuid, bigint, int), private.aios_audit_heads(), private.aios_audit_anchors_list(uuid),
  private.aios_audit_record_anchor(uuid, bigint, uuid, text, timestamptz, text, text, text, jsonb), private.aios_audit_record_external_verification(uuid, bigint, bigint, text, text, boolean, jsonb),
  private.aios_audit_policy_set(interval, interval, text), private.aios_final_verify(boolean, boolean, text), private.aios_scheduled_verify()
  from public, anon, authenticated, service_role;
grant execute on function private.aios_audit_policy_set(interval, interval, text) to aios_restorer;

-- 12. Service-role wrappers (the ONLY client-reachable surface; each is a thin SECURITY DEFINER shim) ---------------------------------------------------
create or replace function public.aios_audit_chain_export(p_organization_id uuid, p_after_count bigint default 0, p_limit int default 500) returns jsonb
language sql security definer set search_path = '' as $fn$ select private.aios_audit_chain_export(p_organization_id, p_after_count, p_limit) $fn$;
create or replace function public.aios_audit_heads() returns jsonb
language sql security definer set search_path = '' as $fn$ select private.aios_audit_heads() $fn$;
create or replace function public.aios_audit_record_anchor(p_organization_id uuid, p_event_count bigint, p_head_event_id uuid, p_head_hash text, p_head_at timestamptz,
  p_evidence_type text, p_artifact_sha256 text, p_artifact_ref text, p_evidence jsonb) returns jsonb
language sql security definer set search_path = '' as $fn$ select private.aios_audit_record_anchor(p_organization_id, p_event_count, p_head_event_id, p_head_hash, p_head_at, p_evidence_type, p_artifact_sha256, p_artifact_ref, p_evidence) $fn$;
create or replace function public.aios_audit_record_external_verification(p_organization_id uuid, p_anchor_id bigint, p_event_count bigint, p_head_hash text, p_report_sha256 text, p_ok boolean, p_details jsonb default '{}'::jsonb) returns jsonb
language sql security definer set search_path = '' as $fn$ select private.aios_audit_record_external_verification(p_organization_id, p_anchor_id, p_event_count, p_head_hash, p_report_sha256, p_ok, p_details) $fn$;
create or replace function public.aios_audit_anchors_list(p_organization_id uuid) returns jsonb
language sql security definer set search_path = '' as $fn$ select private.aios_audit_anchors_list(p_organization_id) $fn$;
create or replace function public.aios_audit_verify() returns jsonb
language sql security definer set search_path = '' as $fn$ select private.aios_final_verify(true, false, 'internal') $fn$;

revoke all on function public.aios_audit_chain_export(uuid, bigint, int), public.aios_audit_heads(), public.aios_audit_anchors_list(uuid),
  public.aios_audit_record_anchor(uuid, bigint, uuid, text, timestamptz, text, text, text, jsonb),
  public.aios_audit_record_external_verification(uuid, bigint, bigint, text, text, boolean, jsonb), public.aios_audit_verify() from public, anon, authenticated;
grant execute on function public.aios_audit_chain_export(uuid, bigint, int), public.aios_audit_heads(), public.aios_audit_anchors_list(uuid),
  public.aios_audit_record_anchor(uuid, bigint, uuid, text, timestamptz, text, text, text, jsonb),
  public.aios_audit_record_external_verification(uuid, bigint, bigint, text, text, boolean, jsonb), public.aios_audit_verify() to service_role;
