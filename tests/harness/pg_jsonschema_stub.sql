-- HARNESS STUB of Supabase's pg_jsonschema (not available in stock PostgreSQL). Supports the JSON-Schema subset AiOS tool schemas use:
-- type, required, properties, additionalProperties(false), enum, minimum, maximum, minLength, maxLength, items. NOT a full validator.
create or replace function extensions.jsonb_matches_schema(schema json, instance jsonb) returns boolean language plpgsql immutable as $$
declare sc jsonb := schema::jsonb; k text; t text; v jsonb; ok boolean := true; e jsonb;
begin
  if sc is null or jsonb_typeof(sc)<>'object' then return true; end if;
  t := sc->>'type';
  if t is not null then
    if t='integer' then if jsonb_typeof(instance)<>'number' or (instance#>>'{}')::numeric <> trunc((instance#>>'{}')::numeric) then return false; end if;
    elsif t='number' then if jsonb_typeof(instance)<>'number' then return false; end if;
    elsif t<>jsonb_typeof(instance) then return false; end if;
  end if;
  if sc ? 'enum' and not (sc->'enum') @> jsonb_build_array(instance) then return false; end if;
  if jsonb_typeof(instance)='number' then
    if sc ? 'minimum' and (instance#>>'{}')::numeric < (sc->>'minimum')::numeric then return false; end if;
    if sc ? 'maximum' and (instance#>>'{}')::numeric > (sc->>'maximum')::numeric then return false; end if;
  end if;
  if jsonb_typeof(instance)='string' then
    if sc ? 'minLength' and length(instance#>>'{}') < (sc->>'minLength')::int then return false; end if;
    if sc ? 'maxLength' and length(instance#>>'{}') > (sc->>'maxLength')::int then return false; end if;
  end if;
  if jsonb_typeof(instance)='object' then
    if sc ? 'required' then for k in select jsonb_array_elements_text(sc->'required') loop if not instance ? k then return false; end if; end loop; end if;
    if sc ? 'properties' then for k, v in select * from jsonb_each(sc->'properties') loop
      if instance ? k and not extensions.jsonb_matches_schema(v::json, instance->k) then return false; end if; end loop; end if;
    if sc->'additionalProperties' = 'false'::jsonb then
      for k in select jsonb_object_keys(instance) loop if not coalesce(sc->'properties' ? k, false) then return false; end if; end loop; end if;
  end if;
  if jsonb_typeof(instance)='array' and sc ? 'items' then
    for e in select jsonb_array_elements(instance) loop if not extensions.jsonb_matches_schema((sc->'items')::json, e) then return false; end if; end loop; end if;
  return true;
end $$;
