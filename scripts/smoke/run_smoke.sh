#!/usr/bin/env bash
# Usage: DATABASE_URL=<read-only connection string> scripts/smoke/run_smoke.sh   (never commit or echo the URL)
# Forces a read-only session; exits 1 if any check is FAIL. WARN/INFO do not fail the run but must be reported.
set -euo pipefail
: "${DATABASE_URL:?set DATABASE_URL}"
out=$(PGOPTIONS='-c default_transaction_read_only=on' psql "$DATABASE_URL" -X -A -F '|' -t -v ON_ERROR_STOP=1 -f "$(dirname "$0")/smoke_readonly.sql")
echo "# $(date -u +%FT%TZ)  commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"; echo "$out"
echo "$out" | sha256sum | sed 's/^/# output sha256: /'
if echo "$out" | grep -q '|FAIL|'; then echo "SMOKE: FAIL"; exit 1; fi
echo "SMOKE: no FAIL ($(echo "$out" | grep -c '|WARN|') WARN)"
