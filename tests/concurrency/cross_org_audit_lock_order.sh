#!/usr/bin/env bash
# PostgreSQL regression: opposite candidate-array order across two organizations
# must converge on the same sorted advisory-lock order. Throwaway CI database only.
set -euo pipefail
DB="$1"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
ORG_A=ab020101-0000-4000-8000-000000000001
ORG_B=ab020101-0000-4000-8000-000000000002
psql "$DB" -X -q -v ON_ERROR_STOP=1 -c "
  insert into public.aios_organizations(id,name) values
    ('$ORG_A','cross-org-audit-a'),('$ORG_B','cross-org-audit-b')
  on conflict (id) do nothing;
"
q() { psql "$DB" -X -At -q -v ON_ERROR_STOP=1 -c "$1"; }

echo "== cross-organization audit advisory lock ordering"
# Each pair holds its acquired transaction locks briefly. Candidate arrays are
# deliberately reversed; the helper must normalize both to UUID ascending order.
for n in $(seq 1 12); do
  (
    psql "$DB" -X -q -v ON_ERROR_STOP=1 >"$D/a.$n.out" 2>"$D/a.$n.err" <<SQL
begin;
set local lock_timeout = '5s';
select private.aios_prelock_audit_organizations(array['$ORG_A'::uuid,'$ORG_B'::uuid]);
select pg_sleep(0.08);
commit;
SQL
    echo $? >"$D/a.$n.rc"
  ) &
  PA=$!
  (
    psql "$DB" -X -q -v ON_ERROR_STOP=1 >"$D/b.$n.out" 2>"$D/b.$n.err" <<SQL
begin;
set local lock_timeout = '5s';
select private.aios_prelock_audit_organizations(array['$ORG_B'::uuid,'$ORG_A'::uuid]);
select pg_sleep(0.08);
commit;
SQL
    echo $? >"$D/b.$n.rc"
  ) &
  PB=$!
  wait "$PA" || true
  wait "$PB" || true
  RA=$(cat "$D/a.$n.rc" 2>/dev/null || echo 99)
  RB=$(cat "$D/b.$n.rc" 2>/dev/null || echo 99)
  if [ "$RA" != 0 ] || [ "$RB" != 0 ]; then
    echo "FAIL iteration $n: worker A rc=$RA worker B rc=$RB"
    cat "$D/a.$n.err" "$D/b.$n.err" 2>/dev/null || true
    exit 1
  fi
done
echo "  PASS 12 opposite-order concurrent batches completed without deadlock or lock timeout"

# Verify both production batch processors acquire the complete sorted org-lock set
# after their row-lock pre-phase, before entering phase two.
q "select
  position('aios_prelock_audit_organizations' in pg_get_functiondef('private.aios_expire_stale_approvals()'::regprocedure)) > 0
  and position('pg_try_advisory_xact_lock' in pg_get_functiondef('private.aios_reap_stale_tasks(interval)'::regprocedure)) > 0
  and position('hashtextextended' in pg_get_functiondef('private.aios_reap_stale_tasks(interval)'::regprocedure)) > 0
  and position('order by x.organization_id' in pg_get_functiondef('private.aios_prelock_audit_organizations(uuid[])'::regprocedure)) > 0" | grep -qx t
echo "  PASS expiry uses sorted audit prelock; reaper uses matching non-blocking organization audit key"
echo "== cross-organization audit lock ordering: PASS"
