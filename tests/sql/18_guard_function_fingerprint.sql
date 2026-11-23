-- Guard registry regression: every migration that rewrites a registered guard function must advance
-- its registered fingerprint. Regression for PR #40 (migration 20261120190000 rewrote the mission
-- status guard, mission terminal cascade and task mission gate without re-pinning them, so
-- private.aios_guard_drift() reported trigger_function_changed and the Part D baseline failed).
-- Runs as the migration owner on the clean replay; the tamper mutant is rolled back.
do $$
declare
  v_drift jsonb;
  v_rows int;
begin
  v_drift := private.aios_guard_drift();
  if (v_drift->>'drift_count')::int <> 0 then
    raise exception 'guard registry drift after replay: %', v_drift->'findings';
  end if;

  -- The three functions rewritten by the succeeded-terminal-integrity migration are registered and pinned.
  select count(*) into v_rows
    from private.aios_guarded_triggers g
   where (g.table_name, g.trigger_name, g.expected_function) in (
           ('aios_missions','trg_aios_mission_status_guard','private.aios_mission_status_guard()'),
           ('aios_missions','trg_aios_mission_terminal_cascade','private.aios_mission_terminal_cascade()'),
           ('aios_tasks','trg_aios_task_mission_gate','private.aios_task_mission_gate()'))
     and g.expected_function_fp = private.aios_function_fingerprint(g.expected_function::regprocedure);
  if v_rows <> 3 then
    raise exception 'expected 3 re-pinned guard registrations for the succeeded-integrity functions, found %', v_rows;
  end if;
end
$$;

-- Mutant: tampering with each guarded function must be detected as trigger_function_changed.
do $$
declare
  v_fn text;
  v_def text;
  v_drift jsonb;
begin
  foreach v_fn in array array['private.aios_mission_status_guard()','private.aios_mission_terminal_cascade()','private.aios_task_mission_gate()'] loop
    begin
      v_def := pg_get_functiondef(v_fn::regprocedure);
      -- semantically inert but byte-different tamper: one comment line at the start of the body
      if position('AS $function$' in v_def) = 0 then raise exception 'unexpected function definition shape for %', v_fn; end if;
      execute replace(v_def, 'AS $function$', 'AS $function$' || chr(10) || '-- tamper');
      v_drift := private.aios_guard_drift();
      if not exists (select 1 from jsonb_array_elements(v_drift->'findings') f
                      where f->>'kind' = 'trigger_function_changed' and f->>'function' = v_fn) then
        raise exception 'MUTANT SURVIVED: tampering with % was not reported as drift: %', v_fn, v_drift;
      end if;
      raise exception using errcode = 'P0001', message = 'rollback-mutant';
    exception when raise_exception then
      if sqlerrm <> 'rollback-mutant' then raise; end if;
    end;
  end loop;
  if (private.aios_guard_drift()->>'drift_count')::int <> 0 then
    raise exception 'mutant rollback left drift behind';
  end if;
end
$$;

select 'ok: guard registry fingerprints match rewritten guard functions' as result;
