#!/usr/bin/env bash
# Canonical AiOS test matrix runner: 45 SQL cases (tests/sql/05) + G4 eight-way concurrency (tests/concurrency),
# verified against tests/matrix/manifest.json. Usage: run.sh <DB_URL> [OUT_DIR]
# Needs: psql, bash, bc, python3. Run against a throwaway database built ONLY from supabase/migrations
# (G4 commits fixtures to the target database, so use a fresh database per run).
set -u
DB="${1:?usage: run.sh <DB_URL> [OUT_DIR]}"; OUT="${2:-tests/matrix/out}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
mkdir -p "$OUT"; rc=0
{
  echo "git_sha=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "psql_client=$(psql --version)"
  echo "server=$(psql "$DB" -At -c 'select version()')"
  echo "migrations=$(ls "$ROOT"/supabase/migrations | wc -l)"
} | tee "$OUT/environment.txt"

echo "== 05_certification_matrix (45 SQL cases)"
psql "$DB" -X -A -t -v ON_ERROR_STOP=1 -f "$ROOT/tests/sql/05_certification_matrix.sql" > "$OUT/sql-05.log" 2>&1 || rc=1
grep -E "^MX_RESULT\||^ok:|ERROR|matrix failures" "$OUT/sql-05.log" | cut -c1-240

echo "== G4 eight-way concurrency"
bash "$ROOT/tests/concurrency/run.sh" "$DB" > "$OUT/g4.log" 2>&1 || rc=1
cat "$OUT/g4.log"

echo "== verify against manifest"
python3 "$HERE/verify.py" --manifest "$HERE/manifest.json" --sql-log "$OUT/sql-05.log" --g4-log "$OUT/g4.log" --report "$OUT/report.json" || rc=1
echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$OUT/environment.txt" >/dev/null
exit $rc
