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
  -- Order by (mission, task, invocation, approval) so concurrent batches acquire in one global order. Missions are locked once, subtree first.
  for r in
    select ap.id as approval_id, t.mission_id
    from public.aios_approvals ap
    left join public.aios_tool_invocations i on i.id = ap.invocation_id
    left join public.aios_tasks t on t.id = i.task_id
    where ap.id = any(p_ids)
    order by t.mission_id nulls last, t.id nulls last, i.id nulls last, ap.id
  loop
    if r.mission_id is not null then
      if r.mission_id is distinct from v_last_mission then perform private.aios_lock_mission_subtree(r.mission_id); v_last_mission := r.mission_id; end if;
    else
      perform private.aios_lock_approval_chain(r.approval_id);
    end if;
  end loop;
end $f$;
revoke all on function private.aios_prelock_approvals_batch(uuid[]) from public, anon, authenticated;
grant execute on function private.aios_prelock_approvals_batch(uuid[]) to service_role;

do $m$
declare d text; n text;
begin
  -- 1. aios_expire_stale_approvals: phase 1 (lock) then phase 2 (process only the locked ids)
  d := pg_get_functiondef('private.aios_expire_stale_approvals()'::regprocedure);
  if position('aios_prelock_approvals_batch' in d) = 0 then
    n := replace(d, E'declare\n  a record;', E'declare\n  a record; v_ids uuid[];');
    if n = d then raise exception 'expire_stale_approvals declare anchor not found'; end if;
    d := n;
    n := regexp_replace(d, E'begin\\s+for a in\\s+select ap\\.id, ap\\.invocation_id, ap\\.organization_id\\s+from public\\.aios_approvals ap\\s+where ap\\.status = ''pending''',
      E'begin\n  -- PHASE 1 (lock only, no writes => no audit lock): candidates are fixed here and every subtree lock is taken BEFORE any audit write.\n'
      || E'  select coalesce(array_agg(c.id), ''{}''::uuid[]) into v_ids from (\n'
      || E'    select ap0.id from public.aios_approvals ap0 where ap0.status = ''pending''\n'
      || E'      and ((ap0.expires_at is not null and ap0.expires_at <= now()) or (ap0.expires_at is null and ap0.created_at < now() - interval ''24 hours''))\n'
      || E'    order by ap0.created_at, ap0.id) c;\n'
      || E'  perform private.aios_prelock_approvals_batch(v_ids);\n'
      || E'  -- PHASE 2: process exactly the pre-locked ids.\n'
      || E'  for a in\n    select ap.id, ap.invocation_id, ap.organization_id\n    from public.aios_approvals ap\n    where ap.id = any(v_ids) and ap.status = ''pending''');
    if n = d then raise exception 'expire_stale_approvals loop anchor not found'; end if;
    execute n;
  end if;
end $m$;
