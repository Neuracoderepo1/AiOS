-- Guard function fingerprints must match after the candidate migration replay.
-- The deliberate body mutation is rolled back; it proves a guard-body edit remains detectable.
begin;
do $guard_fingerprint$
declare v_drift jsonb;
begin
  v_drift := private.aios_guard_drift();
  if coalesce((v_drift->>'drift_count')::integer, -1) <> 0
     or jsonb_array_length(coalesce(v_drift->'findings', '[]'::jsonb)) <> 0 then
    raise exception 'guard drift must be zero after fresh migration replay: %', v_drift;
  end if;
end
$guard_fingerprint$;

create or replace function private.aios_mission_status_guard()
returns trigger language plpgsql security definer set search_path = '' as $mutant$
begin
  return new;
end
$mutant$;

do $guard_mutant$
declare v_drift jsonb; v_count integer;
begin
  v_drift := private.aios_guard_drift();
  select count(*) into v_count
    from jsonb_array_elements(coalesce(v_drift->'findings', '[]'::jsonb)) f
   where f->>'kind' = 'trigger_function_changed'
     and f->>'function' = 'private.aios_mission_status_guard()';
  if v_count <> 1 then raise exception 'guard-body mutant must produce exactly one trigger_function_changed finding: %', v_drift; end if;
end
$guard_mutant$;
rollback;
select 'ok: guard fingerprint baseline and body-mutation regression' as result;
