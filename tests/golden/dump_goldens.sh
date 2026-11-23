#!/usr/bin/env bash
# Dumps environment-independent goldens (no owners, no OIDs): the guarded-trigger registry and the prosrc hashes of the pinned functions.
# Usage: dump_goldens.sh <psql conn args...>  > writes tests/golden/guard_registry.tsv and tests/golden/function_pins.tsv  (or compares with --check)
set -euo pipefail
cd "$(dirname "$0")"; MODE=write; if [ "${1:-}" = "--check" ]; then MODE=check; shift; fi
reg=$(psql "$@" -X -At -F $'\t' -c "select schema_name||'.'||table_name, trigger_name, expected_enabled, restorable, expected_function, expected_trigger_fp from private.aios_guarded_triggers order by 1,2")
pins=$(psql "$@" -X -At -F $'\t' -c "select function_signature, (select md5(prosrc) from pg_proc where oid = function_signature::regprocedure) from private.aios_function_pins order by 1")
if [ "$MODE" = write ]; then printf '%s\n' "$reg" > guard_registry.tsv; printf '%s\n' "$pins" > function_pins.tsv; echo "goldens written"; exit 0; fi
rc=0
diff <(printf '%s\n' "$reg") guard_registry.tsv >/tmp/g1.diff || { echo "GUARD REGISTRY DIFFERS FROM GOLDEN (a migration changed a protected trigger/function without an explicit golden update):"; cat /tmp/g1.diff; rc=1; }
diff <(printf '%s\n' "$pins") function_pins.tsv >/tmp/g2.diff || { echo "PINNED FUNCTION BODY DIFFERS FROM GOLDEN (verifier/canonical hash/drift check changed):"; cat /tmp/g2.diff; rc=1; }
[ $rc = 0 ] && echo "goldens match"; exit $rc
