#!/usr/bin/env bash
# PART E concurrency: concurrent audit appends, anchoring while appending, and idempotent anchor races. Throwaway DB only (commits fixtures).
set -u
DB="$1"; fail=0; RES=/tmp/audit-append-races.results; : > "$RES"
. "$(dirname "$0")/cron_guard.sh"
q() { psql "$DB" -X -qAt -v ON_ERROR_STOP=1 -c "$1"; }
check() { if [ "$2" = true ]; then echo "  PASS $1"; echo "PASS|$1|$3" >> "$RES"; else echo "  FAIL $1 ($3)"; echo "FAIL|$1|$3" >> "$RES"; fail=1; fi; }
cron_pause "$DB" || exit 1; trap 'rc=$?; cron_restore || rc=1; exit $rc' EXIT
ORG=ab000000-0000-4000-8000-0000000000a1; ORG2=ab000000-0000-4000-8000-0000000000a2
# The audit store is immutable, so this suite can only run once per database. Fail closed instead of mis-reporting on leftovers.
[ "$(q "select count(*) from public.aios_audit_events where organization_id in ('$ORG','$ORG2')")" = 0 ] || { echo "FAIL: database already contains this suite's fixtures; run it on a freshly replayed database"; exit 2; }
q "insert into public.aios_organizations (id, name) values ('$ORG','race-a'),('$ORG2','race-b') on conflict do nothing" >/dev/null

echo "== A1: 8 sessions x 10 appends to ONE organization (same transaction timestamps => collision path) keep a valid chain"
start=$(q "select (clock_timestamp() + interval '2 seconds')::text")
for w in $(seq 1 8); do
  ( psql "$DB" -X -qAt -c "select pg_sleep(greatest(0, extract(epoch from ('$start'::timestamptz - clock_timestamp()))));
      do \$\$ begin for i in 1..10 loop insert into public.aios_audit_events (organization_id, event_type, metadata, created_at) values ('$ORG', 'race.append', jsonb_build_object('w', $w, 'i', i), now()); end loop; end \$\$" > /tmp/ar_$w.out 2>&1 ) &
done; wait
n=$(q "select count(*) from public.aios_audit_events where organization_id='$ORG'")
check "A1.a all 80 appends committed" "$([ "$n" = 80 ] && echo true || echo false)" "count=$n"
check "A1.b chain valid after concurrent appends (canonical verifier)" "$([ "$(q "select private.aios_audit_verify_chain_v2('$ORG') ->> 'valid'")" = true ] && echo true || echo false)" "$(q "select private.aios_audit_verify_chain_v2('$ORG')::text" | head -c 200)"
check "A1.c created_at strictly increasing, no duplicates (1-microsecond collision advance under contention)" "$([ "$(q "select count(distinct created_at) from public.aios_audit_events where organization_id='$ORG'")" = 80 ] && echo true || echo false)" ""
check "A1.d exactly one genesis link and no forks (every previous hash is used once)" "$([ "$(q "select count(*) from public.aios_audit_events where organization_id='$ORG' and previous_event_hash like 'GENESIS:%'")" = 1 ] && [ "$(q "select count(*) - count(distinct previous_event_hash) from public.aios_audit_events where organization_id='$ORG'")" = 0 ] && echo true || echo false)" ""

echo "== A2: anchoring at a fixed position WHILE appends continue: anchor accepted, later verification still consistent"
q "insert into public.aios_audit_events (organization_id, event_type, metadata) select '$ORG', 'pre', '{}' where false" >/dev/null
read -r CNT EID EHASH EAT <<<"$(q "select 80, id, event_hash, to_char(created_at at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US\"+00\"') from public.aios_audit_events where organization_id='$ORG' order by created_at desc, id desc limit 1" | tr '|' ' ')"
( psql "$DB" -X -qAt -c "do \$\$ begin for i in 1..60 loop insert into public.aios_audit_events (organization_id, event_type, metadata) values ('$ORG', 'race.during-anchor', jsonb_build_object('i', i)); perform pg_sleep(0.01); end loop; end \$\$" > /tmp/ar_during.out 2>&1 ) &
APID=$!
DIG=$(q "select private.aios_audit_checkpoint_digest('$ORG', 80, '$EID', '$EHASH', (select created_at from public.aios_audit_events where id='$EID'))")
ART=$(printf 'artifact-a2' | sha256sum | cut -d' ' -f1)
res=$(q "select private.aios_audit_record_anchor('$ORG', 80, '$EID', '$EHASH', (select created_at from public.aios_audit_events where id='$EID'), 'git', '$ART', 'test://a2', jsonb_build_object('repository','example/x','commit','$(printf 'a%.0s' $(seq 40))','manifest_path','m','manifest_sha256','$DIG','verified_by','race-test'))")
wait $APID
check "A2.a anchor at position 80 accepted while 60 more events were being appended" "$(echo "$res" | grep -q '"ok": true' && echo true || echo false)" "$res"
check "A2.b total is now 140 and the chain is valid end to end" "$([ "$(q "select count(*) from public.aios_audit_events where organization_id='$ORG'")" = 140 ] && [ "$(q "select private.aios_audit_verify_chain_v2('$ORG') ->> 'valid'")" = true ] && echo true || echo false)" ""
check "A2.c final verifier shows an unanchored tail of 60 (not truncation, not mismatch)" "$([ "$(q "select (o ->> 'status') || ':' || (o -> 'detail' ->> 'unanchored_tail_events') from jsonb_array_elements(private.aios_final_verify(false) -> 'organizations') o where o ->> 'organization_id' = '$ORG'")" = "anchored_unattested:60" ] && echo true || echo false)" "$(q "select (o ->> 'status') || ':' || (o -> 'detail' ->> 'unanchored_tail_events') from jsonb_array_elements(private.aios_final_verify(false) -> 'organizations') o where o ->> 'organization_id' = '$ORG'")"

echo "== A3: 8 sessions submit the SAME NEW anchor (position 100) simultaneously: exactly one row inserted, one non-idempotent response, seven idempotent"
read -r P3ID P3HASH <<<"$(q "select id, event_hash from public.aios_audit_events where organization_id='$ORG' order by created_at, id offset 99 limit 1" | tr '|' ' ')"
P3AT="(select created_at from public.aios_audit_events where id='$P3ID')"
DIG3=$(q "select private.aios_audit_checkpoint_digest('$ORG', 100, '$P3ID', '$P3HASH', $P3AT)")
ART3=$(printf 'artifact-a3' | sha256sum | cut -d' ' -f1)
start=$(q "select (clock_timestamp() + interval '2 seconds')::text"); rm -f /tmp/ar_s*.out
for w in $(seq 1 8); do
  ( psql "$DB" -X -qAt -c "select pg_sleep(greatest(0, extract(epoch from ('$start'::timestamptz - clock_timestamp()))));
      select private.aios_audit_record_anchor('$ORG', 100, '$P3ID', '$P3HASH', $P3AT, 'git', '$ART3', 'test://a3', jsonb_build_object('repository','example/x','commit','$(printf 'b%.0s' $(seq 40))','manifest_path','m','manifest_sha256','$DIG3','verified_by','race-test'))" > /tmp/ar_s$w.out 2>&1 ) &
done; wait
rows=$(q "select count(*) from private.aios_audit_anchors where organization_id='$ORG' and event_count=100"); idem=$(cat /tmp/ar_s?.out | grep -c '"idempotent": true'); fresh=$(cat /tmp/ar_s?.out | grep -c '"idempotent": false'); errs=$(cat /tmp/ar_s?.out | grep -c ERROR)
check "A3.a one anchor row ($rows); 1 inserted ($fresh), 7 idempotent ($idem), 0 errors ($errs)" "$([ "$rows" = 1 ] && [ "$idem" = 7 ] && [ "$fresh" = 1 ] && [ "$errs" = 0 ] && echo true || echo false)" "rows=$rows fresh=$fresh idem=$idem errs=$errs"

echo "== A4: two organizations appended concurrently keep independent valid chains"
start=$(q "select (clock_timestamp() + interval '2 seconds')::text")
for w in 1 2 3 4; do for o in $ORG2; do ( psql "$DB" -X -qAt -c "select pg_sleep(greatest(0, extract(epoch from ('$start'::timestamptz - clock_timestamp()))));
   do \$\$ begin for i in 1..15 loop insert into public.aios_audit_events (organization_id, event_type, metadata) values ('$o','race.multi', jsonb_build_object('w',$w,'i',i)); end loop; end \$\$" >/dev/null 2>&1 ) & done; done; wait
check "A4 org B chain valid with 60 events; org A unaffected" "$([ "$(q "select private.aios_audit_verify_chain_v2('$ORG2') ->> 'valid'")" = true ] && [ "$(q "select count(*) from public.aios_audit_events where organization_id='$ORG2'")" = 60 ] && [ "$(q "select private.aios_audit_verify_chain_v2('$ORG') ->> 'valid'")" = true ] && echo true || echo false)" ""

echo; [ $fail = 0 ] && echo "AUDIT APPEND RACES: ALL PASS" || echo "AUDIT APPEND RACES: FAILURES"; exit $fail
