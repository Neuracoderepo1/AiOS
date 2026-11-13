# Forced PostgreSQL interleaving: mutate the invocation->task binding while the
# chain-lock worker is blocked on the original mission row. The worker must either
# reject the changed post-lock snapshot with 40001, or the database must prove the
# binding column is immutable to the migration runner. Disposable CI stack only.
set -euo pipefail
DB="$1"
D=$(mktemp -d)
EVIDENCE_DIR="\${AIOS_BINDING_EVIDENCE_DIR:-}"
CLEANUP_DONE=0

cleanup() {
  local rc=$?
  local remaining=""
  local termination=""
  if [[ "$CLEANUP_DONE" -eq 1 ]]; then
    return "$rc"
  fi
  CLEANUP_DONE=1
  trap - EXIT
  set +e

  if [[ "$rc" -ne 0 ]]; then
    echo "== approval-chain diagnostic capture (exit=$rc) =="
    for f in blocker.out blocker.err worker.out worker.err blocker.rc worker.rc; do
      echo "-- $f --"
      cat "$D/$f" 2>/dev/null || true
    done
    echo "-- named blocker/worker sessions --"
    q "select pid,application_name,state,wait_event_type,wait_event,pg_blocking_pids(pid) as blocked_by,left(query,500) from pg_stat_activity where application_name in ('aios-binding-blocker','aios-binding-worker')" 2>&1 || true
    echo "-- all non-idle sessions with blocking pids --"
    q "select pid,application_name,state,wait_event_type,wait_event,pg_blocking_pids(pid) as blocked_by,left(query,200) from pg_stat_activity where datname=current_database() and pid<>pg_backend_pid() and state<>'idle' order by pid" 2>&1 || true
    echo "-- ungranted locks --"
    q "select l.pid,l.locktype,l.mode,l.relation::regclass as relation from pg_locks l where not l.granted order by l.pid" 2>&1 || true
    echo "-- recent cron runs --"
    if [[ "$(q "select to_regclass('cron.job_run_details') is not null" 2>/dev/null)" == "t" ]]; then
      q "select jobid,status,start_time,end_time from cron.job_run_details order by start_time desc limit 5" 2>&1 || true
    else
      echo "pg_cron diagnostics unavailable: cron.job_run_details does not exist"
    fi
  fi

  termination=$(q "select pid || ':' || pg_terminate_backend(pid)::text from pg_stat_activity where application_name in ('aios-binding-blocker','aios-binding-worker') and pid<>pg_backend_pid() order by pid" 2>&1)
  if [[ $? -eq 0 ]]; then
    if [[ -n "$termination" ]]; then
      echo "-- targeted backend termination outcomes (pid:terminated) --"
      printf '%s\n' "$termination"
      if grep -q ':false$' <<<"$termination"; then
        echo "FAIL one or more targeted PostgreSQL backends refused termination"
        rc=1
      fi
    else
      echo "-- targeted backend termination outcomes: no remaining named sessions --"
    fi
  else
    echo "FAIL unable to request targeted PostgreSQL backend termination: $termination"
    rc=1
  fi

  for attempt in {1..40}; do
    remaining=$(q "select count(*) from pg_stat_activity where application_name in ('aios-binding-blocker','aios-binding-worker')" 2>/dev/null)
    [[ "$remaining" == "0" ]] && break
    sleep 0.05
  done
  if [[ "$remaining" != "0" ]]; then
    echo "FAIL targeted PostgreSQL sessions remain after termination attempt (count=\${remaining:-unknown})"
    q "select pid,application_name,state,wait_event_type,wait_event,left(query,300) from pg_stat_activity where application_name in ('aios-binding-blocker','aios-binding-worker')" 2>&1 || true
    rc=1
  else
    echo "PASS targeted PostgreSQL sessions absent after cleanup"
  fi

  kill "\${BLOCKER:-}" "\${WORKER:-}" 2>/dev/null || true
  wait "\${BLOCKER:-}" "\${WORKER:-}" 2>/dev/null || true

  if [[ "$rc" -ne 0 ]]; then
    if [[ -n "$EVIDENCE_DIR" ]]; then
      mkdir -p "$EVIDENCE_DIR" 2>/dev/null || true
      cp -a "$D/." "$EVIDENCE_DIR/" 2>/dev/null || true
      echo "Failure diagnostics preserved at: $EVIDENCE_DIR"
    else
      echo "Failure diagnostics preserved at: $D"
      D=""
    fi
  fi
  [[ -z "$D" ]] || rm -rf "$D"
  exit "$rc"
}
trap cleanup EXIT

ORG=ab030101-0000-4000-8000-000000000001
AGT=ab030101-0000-4000-8000-000000000002
REQ=ab030101-0000-4000-8000-000000000003
ADM=ab030101-0000-4000-8000-000000000004
M1=ab030101-0000-4000-8000-000000000005
T1=ab030101-0000-4000-8000-000000000006
M2=ab030101-0000-4000-8000-000000000007
T2=ab030101-0000-4000-8000-000000000008
INV=ab030101-0000-4000-8000-000000000009
q() { psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -c "$1"; }

echo "== approval-chain post-lock binding revalidation"
psql "$DB" -X -q -v ON_ERROR_STOP=1 <<SQL
insert into auth.users(id,aud,role,email) values
 ('$REQ','authenticated','authenticated','bind-req@example.test'),
 ('$ADM','authenticated','authenticated','bind-adm@example.test')
on conflict (id) do nothing;
insert into public.aios_organizations(id,name) values ('$ORG','binding-race-fixture') on conflict (id) do nothing;
insert into public.aios_organization_members(organization_id,user_id,role) values
 ('$ORG','$REQ','member'),('$ORG','$ADM','admin') on conflict do nothing;
insert into public.aios_agents(id,organization_id,agent_key,name,role,status,authority)
values ('$AGT','$ORG','binding-race-agent','binding-race','binding-race','idle',
 jsonb_build_object('risk_level','medium','allowed_tools',jsonb_build_array('support.export_customer_data'),'limits','{}'::jsonb))
on conflict (id) do nothing;
insert into public.aios_contracts(organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active)
values ('$ORG','$AGT',1,'medium',jsonb_build_array('support.export_customer_data'),'{}'::jsonb,true);
insert into public.aios_missions(id,organization_id,title,objective,status)
values ('$M1','$ORG','binding-race-one','binding-race','queued'),
       ('$M2','$ORG','binding-race-two','binding-race','queued');
insert into public.aios_tasks(id,organization_id,mission_id,assigned_agent_id,title,status)
values ('$T1','$ORG','$M1','$AGT','binding-race-one','queued'),
       ('$T2','$ORG','$M2','$AGT','binding-race-two','queued');
insert into public.aios_tool_invocations
 (id,organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key,created_at)
values ('$INV','$ORG','$AGT','$T1','support.export_customer_data','support.export_customer_data',
 jsonb_build_object('scope','binding-race','format','csv'),'low','$REQ',gen_random_uuid(),'binding-race-'||gen_random_uuid(),now());
update public.aios_approvals set invocation_id=null where id =
 (select approval_id from public.aios_tool_invocations where id='$INV');
SQL
APPROVAL=$(q "select approval_id from public.aios_tool_invocations where id='$INV'")
[[ "$APPROVAL" =~ ^[0-9a-f-]{36}$ ]] || { echo "FAIL fixture approval missing"; exit 2; }
[[ "$(q "select count(*) from public.aios_missions where id='$M1'")" = 1 ]] || { echo "FAIL original mission fixture missing"; exit 2; }
[[ "$(q "select count(*) from public.aios_tasks where id='$T1' and mission_id='$M1'")" = 1 ]] || { echo "FAIL original task/mission binding missing"; exit 2; }
[[ "$(q "select task_id from public.aios_tool_invocations where id='$INV'")" = "$T1" ]] || { echo "FAIL invocation/task fixture binding missing"; exit 2; }
[[ "$(q "select private.aios_resolve_approval_invocation('$APPROVAL')")" = "$INV" ]] || { echo "FAIL shared resolver did not select fixture invocation"; exit 2; }

# B holds FOR UPDATE on the original mission and task rows. This conflicts with every row-lock
# strength the lock-chain worker can request, including FOR KEY SHARE. The worker must therefore
# be observed waiting before B commits the task_id change.
(
  PGAPPNAME=aios-binding-blocker psql "$DB" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose >"$D/blocker.out" 2>"$D/blocker.err" <<SQL
begin;
select 1 from public.aios_missions where id='$M1' for update;
select 1 from public.aios_tasks where id='$T1' for update;
select pg_sleep(15);
update public.aios_tool_invocations set task_id='$T2' where id='$INV';
commit;
SQL
  echo $? >"$D/blocker.rc"
) &
BLOCKER=$!
i=0
until [ "$(q "select count(*) from pg_stat_activity where application_name='aios-binding-blocker' and state='active' and query like '%pg_sleep(15)%'")" = 1 ]; do
  if [[ -s "$D/blocker.rc" ]]; then
    echo "FAIL blocker exited before reaching lock-holding phase (rc=$(cat "$D/blocker.rc"))"
    exit 2
  fi
  i=$((i+1))
  if [ "$i" -gt 400 ]; then
    echo "FAIL blocker did not reach lock-holding phase within 20 seconds"
    exit 2
  fi
  sleep 0.05
done

(
  PGAPPNAME=aios-binding-worker psql "$DB" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose >"$D/worker.out" 2>"$D/worker.err" -c "select private.aios_lock_approval_chain('$APPROVAL');"
  echo $? >"$D/worker.rc"
) &
WORKER=$!
i=0
until [ "$(q "select count(*) from pg_stat_activity where application_name='aios-binding-worker' and wait_event_type='Lock'")" = 1 ]; do
  if [[ -s "$D/worker.rc" ]]; then
    echo "FAIL chain-lock worker exited instead of waiting for original mission lock (rc=$(cat "$D/worker.rc"))"
    exit 2
  fi
  i=$((i+1))
  if [ "$i" -gt 400 ]; then
    echo "FAIL chain-lock worker did not block on original mission within 20 seconds"
    echo "approval=$APPROVAL resolver=$(q "select coalesce(private.aios_resolve_approval_invocation('$APPROVAL')::text,'NULL')")"
    exit 2
  fi
  sleep 0.05
done

wait "$BLOCKER" || true
wait "$WORKER" || true
BRC=$(cat "$D/blocker.rc" 2>/dev/null || echo 99)
WRC=$(cat "$D/worker.rc" 2>/dev/null || echo 99)
if [ "$BRC" = 0 ]; then
  if [ "$WRC" = 0 ] || ! grep -q '40001' "$D/worker.err"; then
    echo "FAIL changed binding was not rejected after lock acquisition (worker rc=$WRC)"
    cat "$D/worker.err"
    exit 1
  fi
  echo "  PASS forced binding change committed while worker waited; worker rejected stale snapshot with 40001"
elif grep -q '42501\|immutable\|cannot change' "$D/blocker.err" && [ "$WRC" = 0 ]; then
  echo "  PASS database rejected invocation task_id mutation; post-lock worker completed against immutable binding"
else
  echo "FAIL unexpected blocker/worker outcome (blocker rc=$BRC worker rc=$WRC)"
  cat "$D/blocker.err" "$D/worker.err" 2>/dev/null || true
  exit 1
fi
echo "== approval-chain post-lock binding revalidation: PASS"
 <<<"$termination"; then
        echo "FAIL one or more targeted PostgreSQL backends refused termination"
        rc=1
      fi
    else
      echo "-- targeted backend termination outcomes: no remaining named sessions --"
    fi
  else
    echo "FAIL unable to request targeted PostgreSQL backend termination: $termination"
    rc=1
  fi

  for attempt in {1..40}; do
    remaining=$(q "select count(*) from pg_stat_activity where application_name in ('aios-binding-blocker','aios-binding-worker')" 2>/dev/null)
    if [[ "$remaining" == "0" ]]; then
      break
    fi
    sleep 0.05
  done
  if [[ "$remaining" != "0" ]]; then
    echo "FAIL targeted PostgreSQL sessions remain after termination attempt (count=${remaining:-unknown})"
    q "select pid,application_name,state,wait_event_type,wait_event,left(query,300) from pg_stat_activity where application_name in ('aios-binding-blocker','aios-binding-worker')" 2>&1 || true
    rc=1
  else
    echo "PASS targeted PostgreSQL sessions absent after cleanup"
  fi

  # Backend termination is authoritative; stop and reap the parent subshells too.
  kill "${BLOCKER:-}" "${WORKER:-}" 2>/dev/null || true
  wait "${BLOCKER:-}" "${WORKER:-}" 2>/dev/null || true

  if [[ "$rc" -ne 0 ]]; then
    if [[ -n "$EVIDENCE_DIR" ]]; then
      mkdir -p "$EVIDENCE_DIR" 2>/dev/null || true
      cp -a "$D/." "$EVIDENCE_DIR/" 2>/dev/null || true
      echo "Failure diagnostics preserved at: $EVIDENCE_DIR"
    else
      echo "Failure diagnostics preserved at: $D"
      D=""
    fi
  fi
  if [[ -n "$D" ]]; then
    rm -rf "$D"
  fi
  exit "$rc"
}
trap cleanup EXIT

ORG=ab030101-0000-4000-8000-000000000001
AGT=ab030101-0000-4000-8000-000000000002
REQ=ab030101-0000-4000-8000-000000000003
ADM=ab030101-0000-4000-8000-000000000004
M1=ab030101-0000-4000-8000-000000000005
T1=ab030101-0000-4000-8000-000000000006
M2=ab030101-0000-4000-8000-000000000007
T2=ab030101-0000-4000-8000-000000000008
INV=ab030101-0000-4000-8000-000000000009
q() { psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -c "$1"; }

echo "== approval-chain post-lock binding revalidation"
psql "$DB" -X -q -v ON_ERROR_STOP=1 <<SQL
insert into auth.users(id,aud,role,email) values
 ('$REQ','authenticated','authenticated','bind-req@example.test'),
 ('$ADM','authenticated','authenticated','bind-adm@example.test')
on conflict (id) do nothing;
insert into public.aios_organizations(id,name) values ('$ORG','binding-race-fixture') on conflict (id) do nothing;
insert into public.aios_organization_members(organization_id,user_id,role) values
 ('$ORG','$REQ','member'),('$ORG','$ADM','admin') on conflict do nothing;
insert into public.aios_agents(id,organization_id,agent_key,name,role,status,authority)
values ('$AGT','$ORG','binding-race-agent','binding-race','binding-race','idle',
 jsonb_build_object('risk_level','medium','allowed_tools',jsonb_build_array('support.export_customer_data'),'limits','{}'::jsonb))
on conflict (id) do nothing;
insert into public.aios_contracts(organization_id,agent_id,version,risk_level,allowed_tools,limits,is_active)
values ('$ORG','$AGT',1,'medium',jsonb_build_array('support.export_customer_data'),'{}'::jsonb,true);
insert into public.aios_missions(id,organization_id,title,objective,status)
values ('$M1','$ORG','binding-race-one','binding-race','queued'),
       ('$M2','$ORG','binding-race-two','binding-race','queued');
insert into public.aios_tasks(id,organization_id,mission_id,assigned_agent_id,title,status)
values ('$T1','$ORG','$M1','$AGT','binding-race-one','queued'),
       ('$T2','$ORG','$M2','$AGT','binding-race-two','queued');
insert into public.aios_tool_invocations
 (id,organization_id,agent_id,task_id,tool_name,tool_key,arguments,risk_level,requested_by,request_id,idempotency_key,created_at)
values ('$INV','$ORG','$AGT','$T1','support.export_customer_data','support.export_customer_data',
 jsonb_build_object('scope','binding-race','format','csv'),'low','$REQ',gen_random_uuid(),'binding-race-'||gen_random_uuid(),now());
update public.aios_approvals set invocation_id=null where id =
 (select approval_id from public.aios_tool_invocations where id='$INV');
SQL
APPROVAL=$(q "select approval_id from public.aios_tool_invocations where id='$INV'")
[[ "$APPROVAL" =~ ^[0-9a-f-]{36}$ ]] || { echo "FAIL fixture approval missing"; exit 2; }
[[ "$(q "select count(*) from public.aios_missions where id='$M1'")" = 1 ]] || { echo "FAIL original mission fixture missing"; exit 2; }
[[ "$(q "select count(*) from public.aios_tasks where id='$T1' and mission_id='$M1'")" = 1 ]] || { echo "FAIL original task/mission binding missing"; exit 2; }
[[ "$(q "select task_id from public.aios_tool_invocations where id='$INV'")" = "$T1" ]] || { echo "FAIL invocation/task fixture binding missing"; exit 2; }
[[ "$(q "select private.aios_resolve_approval_invocation('$APPROVAL')")" = "$INV" ]] || { echo "FAIL shared resolver did not select fixture invocation"; exit 2; }

# B holds FOR UPDATE on the original mission and task rows. This conflicts with every row-lock
# strength the lock-chain worker can request, including FOR KEY SHARE. The worker must therefore
# be observed waiting before B commits the task_id change.
(
  PGAPPNAME=aios-binding-blocker psql "$DB" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose >"$D/blocker.out" 2>"$D/blocker.err" <<SQL
begin;
select 1 from public.aios_missions where id='$M1' for update;
select 1 from public.aios_tasks where id='$T1' for update;
select pg_sleep(15);
update public.aios_tool_invocations set task_id='$T2' where id='$INV';
commit;
SQL
  echo $? >"$D/blocker.rc"
) &
BLOCKER=$!
i=0
until [ "$(q "select count(*) from pg_stat_activity where application_name='aios-binding-blocker' and state='active' and query like '%pg_sleep(15)%'")" = 1 ]; do
  if [[ -s "$D/blocker.rc" ]]; then
    echo "FAIL blocker exited before reaching lock-holding phase (rc=$(cat "$D/blocker.rc"))"
    exit 2
  fi
  i=$((i+1))
  if [ "$i" -gt 400 ]; then
    echo "FAIL blocker did not reach lock-holding phase within 20 seconds"
    exit 2
  fi
  sleep 0.05
done

(
  PGAPPNAME=aios-binding-worker psql "$DB" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose >"$D/worker.out" 2>"$D/worker.err" -c "select private.aios_lock_approval_chain('$APPROVAL');"
  echo $? >"$D/worker.rc"
) &
WORKER=$!
i=0
until [ "$(q "select count(*) from pg_stat_activity where application_name='aios-binding-worker' and wait_event_type='Lock'")" = 1 ]; do
  if [[ -s "$D/worker.rc" ]]; then
    echo "FAIL chain-lock worker exited instead of waiting for original mission lock (rc=$(cat "$D/worker.rc"))"
    exit 2
  fi
  i=$((i+1))
  if [ "$i" -gt 400 ]; then
    echo "FAIL chain-lock worker did not block on original mission within 20 seconds"
    echo "approval=$APPROVAL resolver=$(q "select coalesce(private.aios_resolve_approval_invocation('$APPROVAL')::text,'NULL')")"
    exit 2
  fi
  sleep 0.05
done

wait "$BLOCKER" || true
wait "$WORKER" || true
BRC=$(cat "$D/blocker.rc" 2>/dev/null || echo 99)
WRC=$(cat "$D/worker.rc" 2>/dev/null || echo 99)
if [ "$BRC" = 0 ]; then
  if [ "$WRC" = 0 ] || ! grep -q '40001' "$D/worker.err"; then
    echo "FAIL changed binding was not rejected after lock acquisition (worker rc=$WRC)"
    cat "$D/worker.err"
    exit 1
  fi
  echo "  PASS forced binding change committed while worker waited; worker rejected stale snapshot with 40001"
elif grep -q '42501\|immutable\|cannot change' "$D/blocker.err" && [ "$WRC" = 0 ]; then
  echo "  PASS database rejected invocation task_id mutation; post-lock worker completed against immutable binding"
else
  echo "FAIL unexpected blocker/worker outcome (blocker rc=$BRC worker rc=$WRC)"
  cat "$D/blocker.err" "$D/worker.err" 2>/dev/null || true
  exit 1
fi
echo "== approval-chain post-lock binding revalidation: PASS"
