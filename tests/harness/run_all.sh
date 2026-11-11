#!/usr/bin/env bash
# Runs EVERY Part D/E suite against an already-migrated database and writes raw logs + machine-readable results to <outdir>.
# Usage: run_all.sh <outdir> <conninfo>      conninfo must be a SUPERUSER on a THROWAWAY database (suites commit fixtures; audit races need a fresh DB).
# A missing runtime (deno, openssl, git, python3) is recorded as BLOCKED, never as PASS.
set -u; cd "$(dirname "$0")/../.."; OUT="$1"; CONN="$2"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
DENO="${DENO:-$(command -v deno || true)}"; rc=0
note() { echo "== $*"; }
note "repository state"; { git rev-parse HEAD; git status --short --branch; git log -3 --oneline; } > "$OUT/repository-state.txt" 2>&1
ls supabase/migrations > "$OUT/migration-inventory.txt"
note "static checks + mutation self-test"; python3 tests/static/check_part_de.py > "$OUT/static.log" 2>&1 || rc=1; bash tests/static/selftest.sh > "$OUT/static-selftest.log" 2>&1 || rc=1
note "goldens (guard registry, pinned functions)"; bash tests/golden/dump_goldens.sh --check "$CONN" > "$OUT/goldens.log" 2>&1 || rc=1
note "existing regression SQL suites (tests/sql)"; : > "$OUT/regression-sql.log"
for t in tests/sql/*.sql; do if psql "$CONN" -X -q -v ON_ERROR_STOP=1 -f "$t" > /tmp/reg.out 2>&1; then echo "PASS $t" >> "$OUT/regression-sql.log"; else echo "FAIL $t :: $(grep -m1 -E 'ERROR|FAIL' /tmp/reg.out | cut -c1-200)" >> "$OUT/regression-sql.log"; rc=1; fi; done
note "Part D SQL suite"; psql "$CONN" -X -qAt -f tests/sql_superuser/12_part_d_restoration.sql > "$OUT/sql12.log" 2>&1 || rc=1
note "Part E SQL suite"; psql "$CONN" -X -qAt -f tests/sql_superuser/13_part_e_audit_anchoring.sql > "$OUT/sql13.log" 2>&1 || rc=1
note "Edge Function (deno check + tests)"
if [ -n "$DENO" ]; then ( cd supabase/functions/audit-anchor && "$DENO" check *.ts && "$DENO" test --no-prompt ) > "$OUT/deno.log" 2>&1 || rc=1; else echo "BLOCKED: deno not available" > "$OUT/deno.log"; rc=1; fi
note "RPC tool tests"; python3 -m unittest -v tests.external.test_rpc_tools > "$OUT/rpc.log" 2>&1 || rc=1
note "external verifier e2e (db -> artifacts -> db -> verifier)"; AIOS_E2E_DIR="$OUT/e2e-fixtures" bash tests/external/e2e.sh "$CONN" > "$OUT/e2e.log" 2>&1 || rc=1
note "restoration concurrency (forced interleavings + mutant)"; bash tests/concurrency/restoration_races.sh "$CONN" > "$OUT/races-restoration.log" 2>&1 || rc=1; cp /tmp/restoration-races.results "$OUT/races-restoration.results" 2>/dev/null || true
note "audit append/anchor concurrency"; bash tests/concurrency/audit_append_races.sh "$CONN" > "$OUT/races-audit.log" 2>&1 || rc=1; cp /tmp/audit-append-races.results "$OUT/races-audit.results" 2>/dev/null || true
note "inventory"; bash tests/harness/inventory.sh "$CONN" "$OUT" > "$OUT/inventory.log" 2>&1 || rc=1
cp tests/golden/audit-golden-vectors.json "$OUT/audit-golden-vectors.json"
python3 tests/harness/collect_results.py "$OUT" > "$OUT/collect.log" 2>&1 || rc=1
tail -3 "$OUT/collect.log"; [ $rc = 0 ] && echo "RUN_ALL: ALL SUITES PASSED" || echo "RUN_ALL: FAILURES OR BLOCKED SUITES (see logs)"; exit $rc
