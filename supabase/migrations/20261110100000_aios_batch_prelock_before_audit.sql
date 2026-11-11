-- L3 root-cause remediation: the per-organization audit advisory lock must never be held while a transaction WAITS for a row lock.
-- STATUS: PROPOSED. Not deployed. Requires Human Director authorization (merging to main deploys).
--
-- ROOT CAUSE (reproduced on real PostgreSQL 16, server deadlock graph, L3: expiry job vs mission cancel):
--   private.aios_audit_append() takes pg_advisory_xact_lock(hash(organization_id)) - an ORG-WIDE lock held to the end of the transaction.
--   aios_expire_stale_approvals() processes every lapsed approval in ONE transaction. Iteration 1 writes audit events (=> holds the org audit lock),
--   iteration 2 then requests row locks (mission/task/invocation/approval chain). A concurrent mission cancel holds that mission row and requests the
--   audit lock from its AFTER trigger (aios_log_mission_status). Cycle:  expiry --row--> cancel --audit--> expiry.  Victim: the cancellation.
--   The existing global order (mission -> task -> invocation -> approval) is correct for row locks but the audit lock sat at an UNCONTROLLED position.
--
-- FIX (no audit behaviour is changed: same lock, same hash algorithm, same events, same ordering guarantees):
--   Position the audit lock LAST by construction. The batch jobs now run in two phases inside the same transaction:
--     phase 1  lock the complete mission subtree of every candidate, in the global order, sorted by id; NO writes happen, so no audit lock is taken;
--     phase 2  process exactly the ids locked in phase 1 (anything that lapses later is left for the next run).
--   Locking the whole subtree (not only the approval's chain) matters because a mission-terminal cascade touches sibling tasks/invocations/approvals.
--   Lock acquisition order (single, global):  Mission -> Task(s) by id -> Invocation(s) by id -> Approval(s) by id -> AuditOrg (advisory, via first audit write).
--   Same-class locks are always taken in ascending id order, so two batch workers cannot deadlock on each other.
--
-- This migration changes lock acquisition, plus ONE error-handling correction (lock conflicts are deferred, never recorded as permanent dispositions).
-- (Previous draft rewrote the function with a regexp over pg_get_functiondef; the bodies below are now explicit so the diff shows exactly what is deployed.)
-- Original sentence follows:
-- This migration changes ONLY lock acquisition. No validation, authorization, state transition or audit field is added, removed or weakened.

create or replace function private.aios_lock_mission_subtree(p_mission_id uuid)
returns void language plpgsql security definer set search_path = '' as $f$
begin
  if p_mission_id is null then return; end if;
  perform 1 from public.aios_missions where id = p_mission_id for no key update;
  perform 1 from public.aios_tasks where mission_id = p_mission_id order by id for no key update;
  perform 1 from public.aios_tool_invocations i where i.task_id in (select t.id from public.aios_tasks t where t.mission_id = p_mission_id) order by i.id for update;
  perform 1 from public.aios_approvals a where a.invocation_id in (select i.id from public.aios_tool_invocations i join public.aios_tasks t on t.id = i.task_id where t.mission_id = p_mission_id) order by a.id for update;
end $f$;
revoke all on function private.aios_lock_mission_subtree(uuid) from public, anon, authenticated;
grant execute on function private.aios_lock_mission_subtree(uuid) to service_role;

-- Orphan approvals (no task/mission) have no subtree: lock the approval chain exactly as before.
create or replace function private.aios_prelock_approvals_batch(p_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $f$
declare r record; v_last_mission uuid := null;
begin
  -- Resolve the same effective invocation as aios_lock_approval_chain: prefer the direct FK,
  -- then fall back to the reverse invocation.approval_id link. Reverse-linked approvals are NOT orphans.
  -- Sort every real chain by its actual mission/task/invocation/approval tuple before taking any lock.
  for r in
    select ap.id as approval_id, i.id as invocation_id, i.task_id, t.mission_id
    from public.aios_approvals ap
    left join lateral (
      select candidate.id, candidate.task_id
      from (
        select i0.id, i0.task_id, 0 as link_priority
        from public.aios_tool_invocations i0
        where i0.id = ap.invocation_id
        union all
        select i1.id, i1.task_id, 1 as link_priority
        from public.aios_tool_invocations i1
        where ap.invocation_id is null and i1.approval_id = ap.id
      ) candidate
      order by candidate.link_priority, candidate.id
      limit 1
    ) i on true
    left join public.aios_tasks t on t.id = i.task_id
    where ap.id = any(p_ids)
    order by t.mission_id nulls last, t.id nulls last, i.id nulls last, ap.id
  loop
    if r.mission_id is not null then
      if r.mission_id is distinct from v_last_mission then perform private.aios_lock_mission_subtree(r.mission_id); v_last_mission := r.mission_id; end if;
    else
      -- Truly orphaned approvals have no effective invocation/task/mission.
      perform private.aios_lock_approval_chain(r.approval_id);
    end if;
  end loop;
end $f$;
revoke all on function private.aios_prelock_approvals_batch(uuid[]) from public, anon, authenticated;
grant execute on function private.aios_prelock_approvals_batch(uuid[]) to service_role;

-- A lock conflict is a property of timing, not of the record. These SQLSTATEs must never be turned into permanent per-record verdicts.
create or replace function private.aios_is_lock_conflict(p_sqlstate text)
returns boolean language sql immutable set search_path = '' as $f$
  select p_sqlstate in ('40P01', '40001', '55P03', '57014')   -- deadlock_detected, serialization_failure, lock_not_available, query_canceled (statement/lock timeout)
$f$;
revoke all on function private.aios_is_lock_conflict(text) from public, anon, authenticated;
grant execute on function private.aios_is_lock_conflict(text) to service_role;

-- Reaper candidates: lock each mission subtree once, ascending mission id (global order); tasks without a mission are locked by id last.
create or replace function private.aios_prelock_tasks_batch(p_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $f$
declare r record; v_last_mission uuid := null;
begin
  for r in
    select t.id as task_id, t.mission_id from public.aios_tasks t where t.id = any(p_ids)
    order by t.mission_id nulls last, t.id
  loop
    if r.mission_id is not null then
      if r.mission_id is distinct from v_last_mission then perform private.aios_lock_mission_subtree(r.mission_id); v_last_mission := r.mission_id; end if;
    else
      perform 1 from public.aios_tasks where id = r.task_id for no key update;
    end if;
  end loop;
end $f$;
revoke all on function private.aios_prelock_tasks_batch(uuid[]) from public, anon, authenticated;
grant execute on function private.aios_prelock_tasks_batch(uuid[]) to service_role;

-- aios_expire_stale_approvals: explicit definition = current definition (20261108150000) + phase-1 pre-lock + lock-conflict deferral.
create or replace function private.aios_expire_stale_approvals()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $body$
declare
  a record; v_ids uuid[]; v_lock_deferred int := 0;
  v_inv uuid; v_inv_status text; v_task uuid; v_mission uuid; v_defect text;
  d_expired int; d_orphans int; d_tasks int; d_skipped int;
  v_expired int := 0; v_tasks_expired int := 0; v_orphans int := 0; v_skipped int := 0;
  v_invalid_n int := 0; v_error_n int := 0; v_record_fail int := 0;
  v_invalid jsonb := '[]'::jsonb;
begin
  -- PHASE 1 (lock only, no writes => no audit lock): candidates are fixed here and every subtree lock is taken BEFORE any audit write.
  select coalesce(array_agg(c.id), '{}'::uuid[]) into v_ids from (
    select ap0.id from public.aios_approvals ap0 where ap0.status = 'pending'
      and ((ap0.expires_at is not null and ap0.expires_at <= now()) or (ap0.expires_at is null and ap0.created_at < now() - interval '24 hours'))
    order by ap0.created_at, ap0.id) c;
  perform private.aios_prelock_approvals_batch(v_ids);
  -- PHASE 2: process exactly the pre-locked ids.
  for a in
    select ap.id, ap.invocation_id, ap.organization_id
    from public.aios_approvals ap
    where ap.id = any(v_ids) and ap.status = 'pending'
      and ((ap.expires_at is not null and ap.expires_at <= now())
        or (ap.expires_at is null and ap.created_at < now() - interval '24 hours'))
    order by ap.created_at
    loop
    v_defect := private.aios_approval_binding_defect(a.id);

    if v_defect is null then
      -- Per-record sub-transaction: an unforeseen failure rolls back only this record and never the batch.
      begin
        d_expired := 0; d_orphans := 0; d_tasks := 0; d_skipped := 0;
      perform private.aios_lock_approval_chain(a.id);
      perform 1 from public.aios_approvals ap2 where ap2.id = a.id and ap2.status = 'pending'
        and ((ap2.expires_at is not null and ap2.expires_at <= now()) or (ap2.expires_at is null and ap2.created_at < now() - interval '24 hours'))
        for update skip locked;
      if not found then continue; end if;

        v_inv := a.invocation_id; v_inv_status := null;
        if v_inv is null then
          select i.id into v_inv from public.aios_tool_invocations i where i.approval_id = a.id order by i.created_at desc limit 1;
        end if;
        if v_inv is not null then
          select i.status into v_inv_status from public.aios_tool_invocations i where i.id = v_inv for update;
        end if;

        if v_inv is not null and v_inv_status is distinct from 'requires_approval' then
          -- A linked invocation in any state other than requires_approval may be in flight: never expire its approval here.
          d_skipped := 1;
        else
          update public.aios_approvals
            set status = 'expired', reviewed_at = now(),
                approval_reason = coalesce(approval_reason, 'approval expired before a decision was made')
            where id = a.id and status = 'pending';

          if v_inv is null then
            d_orphans := 1;
          else
            v_task := null;
            update public.aios_tool_invocations
              set status = 'expired', completed_at = now(), error_code = 'APPROVAL_EXPIRED',
                  error_message = 'approval expired before a decision was made'
              where id = v_inv and status = 'requires_approval'
              returning task_id into v_task;
            d_expired := 1;

            if v_task is not null then
              v_mission := null;
              update public.aios_tasks
                set status = 'expired', failed_stage = 'approval_expired',
                    last_error = 'approval expired before a decision was made',
                    result = coalesce(result, '{}'::jsonb) || jsonb_build_object('error', 'approval_expired', 'invocation_id', v_inv)
                where id = v_task and status in ('blocked_pending_approval', 'running')
                returning mission_id into v_mission;
              if v_mission is not null then
                d_tasks := 1;
                update public.aios_missions m set status = 'failed', completed_at = now()
                  where m.id = v_mission and m.status in ('running', 'blocked_pending_approval')
                    and not exists (
                      select 1 from public.aios_tasks s
                      where s.mission_id = m.id
                        and s.status in ('queued','assigned','ready','running','approved','blocked_pending_approval'));
              end if;
            end if;
          end if;
        end if;

        v_expired := v_expired + d_expired; v_orphans := v_orphans + d_orphans;
        v_tasks_expired := v_tasks_expired + d_tasks; v_skipped := v_skipped + d_skipped;
      exception when others then
        if private.aios_is_lock_conflict(sqlstate) then
          -- A lock conflict (deadlock victim, serialization failure, lock/statement timeout) says nothing about the record. It must NEVER become a permanent
          -- manual_review disposition: roll back this record only (already done by the handler), leave it pending, and retry on the next run.
          v_defect := null; v_lock_deferred := v_lock_deferred + 1;
        else
          v_defect := 'transition_error:' || sqlstate;
          v_error_n := v_error_n + 1;
        end if;
      end;
    else
      v_invalid_n := v_invalid_n + 1;
    end if;

    if v_defect is not null then
      -- Reported in the return value and recorded durably (append-only; one row per approval, never rewritten).
      v_invalid := v_invalid || jsonb_build_array(jsonb_build_object('approval_id', a.id, 'defect', v_defect));
      begin
        insert into public.aios_backlog_dispositions
          (organization_id, entity_type, entity_id, classification, disposition, rationale, decided_by)
        values (a.organization_id, 'approval', a.id, 'needs_owner_review', 'manual_review',
                'Pending approval skipped by the convergence job because it cannot be transitioned safely (' || v_defect ||
                '). Record left unmodified; requires owner review. Detected automatically.',
                'job:aios_expire_stale_approvals')
        on conflict do nothing;
      exception when others then
        if private.aios_is_lock_conflict(sqlstate) then v_lock_deferred := v_lock_deferred + 1; else v_record_fail := v_record_fail + 1; end if;
      end;
    end if;
  end loop;

  return jsonb_build_object('approvals_expired', v_expired, 'orphan_approvals_expired', v_orphans,
                            'tasks_expired', v_tasks_expired, 'skipped_in_flight', v_skipped,
                            'invalid_bindings_skipped', v_invalid_n, 'transition_errors_skipped', v_error_n,
                            'disposition_record_failures', v_record_fail, 'lock_conflicts_deferred', v_lock_deferred,
                            'skipped_records', v_invalid);
end; $body$;

-- aios_reap_stale_tasks: explicit definition = current definition + phase-1 pre-lock (same latent audit-lock inversion as the expiry job).
create or replace function private.aios_reap_stale_tasks(p_max_age interval DEFAULT '00:10:00'::interval)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $body$
declare
  r record; v_ids uuid[];
  inv record;
  v_failed int := 0; v_blocked int := 0; v_skipped int := 0;
  v_stage text; v_note text;
begin
  -- PHASE 1 (lock only, no writes => no audit lock): fix the candidate set and take every mission-subtree lock BEFORE any audit write.
  select coalesce(array_agg(c.id), '{}'::uuid[]) into v_ids from (
    select t0.id from public.aios_tasks t0 where t0.status = 'running' and t0.updated_at < now() - p_max_age order by t0.updated_at, t0.id) c;
  perform private.aios_prelock_tasks_batch(v_ids);
  -- PHASE 2: process exactly the pre-locked ids.
  for r in
    select t.id, t.organization_id, t.mission_id
    from public.aios_tasks t
    where t.id = any(v_ids) and t.status = 'running' and t.updated_at < now() - p_max_age
    order by t.updated_at, t.id
    loop
    if r.mission_id is not null then perform 1 from public.aios_missions where id = r.mission_id for no key update; end if;
    perform 1 from public.aios_tasks t2 where t2.id = r.id and t2.status = 'running' and t2.updated_at < now() - p_max_age for update skip locked;
    if not found then continue; end if;
    select i.id, i.status into inv
    from public.aios_tool_invocations i
    where i.task_id = r.id and i.organization_id = r.organization_id
    order by i.created_at desc limit 1;

    if found and inv.status = 'requires_approval' then
      update public.aios_tasks set status = 'blocked_pending_approval'
        where id = r.id and status = 'running';
      update public.aios_missions set status = 'blocked_pending_approval'
        where id = r.mission_id and status = 'running';
      v_blocked := v_blocked + 1;

    elsif found and inv.status not in ('succeeded', 'failed', 'denied') then
      -- executing / approved / unknown: the tool may be in flight. Do not guess; leave for an operator.
      v_skipped := v_skipped + 1;

    else
      if not found then
        v_stage := 'before_invocation';
        v_note := 'Task stalled before any tool invocation was recorded (model proposal stage). No tool was executed.';
      elsif inv.status = 'succeeded' then
        v_stage := 'final_analysis';
        v_note := 'Tool already succeeded; task stalled during final analysis. Tool result is preserved on the invocation and was not re-executed.';
      else
        v_stage := 'invocation_' || inv.status;
        v_note := 'Invocation reached terminal state ' || inv.status || ' but the task was not closed.';
      end if;

      update public.aios_tasks
        set status = 'failed', failed_stage = v_stage, last_error = v_note,
            result = coalesce(result, '{}'::jsonb) || jsonb_build_object(
              'error', 'stale_task_reaped', 'failed_stage', v_stage,
              'invocation_id', case when found then inv.id else null end, 'note', v_note)
        where id = r.id and status = 'running';

      update public.aios_missions m set status = 'failed', completed_at = now()
        where m.id = r.mission_id and m.status = 'running'
          and not exists (
            select 1 from public.aios_tasks s
            where s.mission_id = m.id
              and s.status in ('queued','assigned','ready','running','approved','blocked_pending_approval'));
      v_failed := v_failed + 1;
    end if;
  end loop;

  return jsonb_build_object('failed', v_failed, 'blocked_pending_approval', v_blocked, 'skipped_needs_operator', v_skipped, 'max_age', p_max_age::text);
end; $body$;
