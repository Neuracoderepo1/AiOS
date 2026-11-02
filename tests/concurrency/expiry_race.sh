#!/usr/bin/env bash
# Additive (not part of the historical matrix): N parallel expiry workers must converge exactly once per approval.
# Usage: expiry_race.sh <DB_URL>. Throwaway CI database only (commits fixtures).
set -u
DB="$1"; N=8; fail=0; ORG=e9000000-0000-4000-8000-000000000001
q() { psql "$DB" -At -v ON_ERROR_STOP=1 -c "$1"; }
q "insert into public.aios_organizations (id,name) values ('$ORG','exp-race-org') on conflict do nothing" >/dev/null
q "begin; set local session_replication_role = replica; insert into public.aios_approvals (organization_id,action,risk_level,status,created_at) select '$ORG','race','low','pending', now() - interval '3 days' - (g||' minutes')::interval from generate_series(1,24) g; commit;" >/dev/null || { echo "fixture failed"; exit 1; }
rm -f /tmp/er_*.out
for i in $(seq 1 $N); do psql "$DB" -At -c "select (private.aios_expire_stale_approvals()->>'orphan_approvals_expired')" > /tmp/er_$i.out 2>&1 & done; wait
errs=$(cat /tmp/er_*.out | grep -ci error); total=$(cat /tmp/er_*.out | grep -E '^[0-9]+$' | paste -sd+ | bc)
left=$(q "select count(*) from public.aios_approvals where organization_id='$ORG' and status='pending'")
exp=$(q "select count(*) from public.aios_approvals where organization_id='$ORG' and status='expired'")
dup=$(q "select count(*) from (select approval_id from public.aios_audit_events where organization_id='$ORG' and event_type='approval_changed' and new_state='expired' group by approval_id having count(*)<>1) x")
aud=$(q "select count(distinct approval_id) from public.aios_audit_events where organization_id='$ORG' and event_type='approval_changed' and new_state='expired'")
check() { if [ "$2" = "true" ]; then echo "  PASS $1"; else echo "  FAIL $1"; fail=1; fi; }
echo "== expiry race: $N workers, 24 approvals; sum_expired=$total errors=$errs pending_left=$left expired=$exp audited=$aud dup_audit=$dup"
check "no worker errors" "$([ "$errs" = 0 ] && echo true || echo false)"
check "each approval expired exactly once across workers" "$([ "$total" = 24 ] && echo true || echo false)"
check "none left pending" "$([ "$left" = 0 ] && echo true || echo false)"
check "exactly one expiry audit event per approval" "$([ "$dup" = 0 ] && [ "$aud" = 24 ] && echo true || echo false)"
exit $fail
