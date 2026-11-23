-- Deterministic fixture: fixed ids and timestamps => reproducible hashes across transactions. Included by e2e.sh (phases 1 and 3).
insert into public.aios_organizations (id, name) values ('e2e00000-0000-4000-8000-0000000000e1', 'e2e-fixture');
insert into public.aios_audit_events (id, organization_id, event_type, tool_name, metadata, created_at)
select ('e2e00000-0000-4000-8001-' || lpad(i::text, 12, '0'))::uuid, 'e2e00000-0000-4000-8000-0000000000e1', 'e2e.event', case when i % 3 = 0 then '' else 'tool' end,
       case i when 2 then '{"k":"héllo 世界 😀 \u0001 q\" b\\","n":[1,2.50,null],"z":{"b":1,"a":2}}'::jsonb
              when 5 then '{"big":12345678901234567890.123456789,"e":1e3}'::jsonb else jsonb_build_object('i', i) end,
       timestamptz '2026-03-01 00:00:00+00' + (i || ' minutes')::interval + (case when i = 4 then 123456 else 0 end || ' microseconds')::interval
from generate_series(1, 12) i order by i;
