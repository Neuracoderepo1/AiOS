-- F-40-07: 'succeeded' is a legacy, seed-only mission state. The state machine must
--   * reject every transition INTO 'succeeded' from each active state,
--   * reject every transition OUT of 'succeeded',
--   * keep 'completed' as the working success terminal (positive control),
--   * still allow a mission to exist in 'succeeded' via direct INSERT (historical rows).
begin;

insert into public.aios_organizations (id, name)
values ('19000000-0000-4000-8000-000000000001', 'succeeded-legacy-org');

insert into public.aios_missions (id, organization_id, title, objective, status) values
  ('19100000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000001','queued','t','queued'),
  ('19100000-0000-4000-8000-000000000002','19000000-0000-4000-8000-000000000001','running','t','queued'),
  ('19100000-0000-4000-8000-000000000003','19000000-0000-4000-8000-000000000001','blocked','t','queued'),
  ('19100000-0000-4000-8000-000000000004','19000000-0000-4000-8000-000000000001','control','t','queued');

update public.aios_missions set status = 'running'
 where id in ('19100000-0000-4000-8000-000000000002','19100000-0000-4000-8000-000000000003','19100000-0000-4000-8000-000000000004');
update public.aios_missions set status = 'blocked_pending_approval'
 where id = '19100000-0000-4000-8000-000000000003';

do $legacy$
declare
  v_id uuid;
  v_from text;
  v_err text;
begin
  -- Negative: queued / running / blocked_pending_approval -> succeeded are all refused,
  -- and the mission row is unchanged afterwards.
  for v_id, v_from in
    select id, status from public.aios_missions
     where id in ('19100000-0000-4000-8000-000000000001','19100000-0000-4000-8000-000000000002','19100000-0000-4000-8000-000000000003')
  loop
    v_err := null;
    begin
      update public.aios_missions set status = 'succeeded' where id = v_id;
    exception when others then
      v_err := sqlerrm;
    end;
    if v_err is null then
      raise exception 'F-40-07: % -> succeeded was allowed', v_from;
    end if;
    if v_err not like 'invalid mission state transition: % -> succeeded' then
      raise exception 'F-40-07: % -> succeeded refused for the wrong reason: %', v_from, v_err;
    end if;
    if (select status from public.aios_missions where id = v_id) <> v_from then
      raise exception 'F-40-07: refused transition mutated the mission (%)', v_from;
    end if;
  end loop;

  -- Positive control: the guard still lets a running mission complete.
  update public.aios_missions set status = 'completed' where id = '19100000-0000-4000-8000-000000000004';
  if (select status from public.aios_missions where id = '19100000-0000-4000-8000-000000000004') <> 'completed' then
    raise exception 'F-40-07: running -> completed control transition failed';
  end if;

  -- Legacy rows: a mission can be inserted directly in 'succeeded' ...
  insert into public.aios_missions (id, organization_id, title, objective, status)
  values ('19100000-0000-4000-8000-000000000005','19000000-0000-4000-8000-000000000001','legacy','t','succeeded');
  if (select status from public.aios_missions where id = '19100000-0000-4000-8000-000000000005') <> 'succeeded' then
    raise exception 'F-40-07: legacy succeeded insert was not preserved';
  end if;

  -- ... but it is terminal: no transition out of it.
  foreach v_from in array array['queued','running','blocked_pending_approval','completed','failed','cancelled','expired'] loop
    v_err := null;
    begin
      update public.aios_missions set status = v_from where id = '19100000-0000-4000-8000-000000000005';
    exception when others then
      v_err := sqlerrm;
    end;
    if v_err is null or v_err not like 'invalid mission state transition: succeeded -> %' then
      raise exception 'F-40-07: succeeded -> % was not refused as an invalid transition (got %)', v_from, v_err;
    end if;
  end loop;
  if (select status from public.aios_missions where id = '19100000-0000-4000-8000-000000000005') <> 'succeeded' then
    raise exception 'F-40-07: legacy succeeded mission changed state';
  end if;
end
$legacy$;

rollback;

select 'ok: succeeded is legacy-only (no transition in or out)' as result;
