-- Restore-target emptiness preflight. READ-ONLY: only SELECTs pg_catalog.
-- restore_local.sh runs this with default_transaction_read_only=on, so it cannot
-- modify the target even if edited incorrectly.
--
-- Output: one line per pre-existing USER object, formatted "<class>:<name>".
-- Zero lines means the target is acceptable. Names are for operator diagnosis only.
--
-- Scope (ENUMERATED classes, all namespace-local):
--   schemas, relations of EVERY relkind (tables, partitioned tables, indexes,
--   partitioned indexes, sequences, views, materialized views, composite types,
--   foreign tables), routines (functions, procedures, aggregates, window functions),
--   non-implicit types (base, domain, enum, range), collations, conversions,
--   operators, operator classes, operator families, text-search configurations,
--   dictionaries, parsers and templates, and extended statistics.
--
-- Deliberately NOT counted (never user objects):
--   * Objects in pg_catalog, information_schema, pg_toast and pg_temp* schemas.
--   * The standard `public` schema itself (its CONTENTS are checked).
--   * Row types and array types: implicit companions of a relation or type that is
--     counted in its own right.
--   * Pseudo-types and implicit multirange types.
--   * Objects that belong to an installed extension (pg_depend deptype 'e'), so a
--     clean installation with standard or Supabase extensions is not a false positive.
--
-- NOT enumerated (no namespace; out of this preflight's scope): extensions
-- themselves, event triggers, publications and subscriptions, foreign data wrappers
-- and servers, user mappings, casts, transforms, procedural languages, default
-- privileges, and roles. A collision in one of these is not predicted here; it is
-- stopped by pg_restore --single-transaction --exit-on-error, which rolls the whole
-- restore back. See docs/operations/LOGICAL-EXPORT-RESTORE.md.
with
scope_ns as (
  select n.oid, n.nspname
  from pg_namespace n
  where n.nspname <> 'information_schema'
    and n.nspname !~ '^pg_'
),
ext_members as (
  select d.classid, d.objid
  from pg_depend d
  where d.refclassid = 'pg_extension'::regclass
    and d.deptype = 'e'
),
found as (
  select 'schema' as class, quote_ident(n.nspname) as name
  from scope_ns n
  where n.nspname <> 'public'
    and not exists (select 1 from ext_members e where e.classid = 'pg_namespace'::regclass and e.objid = n.oid)

  union all
  select 'relation[' || c.relkind::text || ']', quote_ident(n.nspname) || '.' || quote_ident(c.relname)
  from pg_class c join scope_ns n on n.oid = c.relnamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_class'::regclass and e.objid = c.oid)

  union all
  select 'routine[' || p.prokind::text || ']',
         quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p join scope_ns n on n.oid = p.pronamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_proc'::regclass and e.objid = p.oid)

  union all
  select 'type[' || t.typtype::text || ']', quote_ident(n.nspname) || '.' || quote_ident(t.typname)
  from pg_type t join scope_ns n on n.oid = t.typnamespace
  where t.typtype not in ('p', 'm')
    and t.typrelid = 0
    and not exists (select 1 from pg_type b where b.typarray = t.oid)
    and not exists (select 1 from ext_members e where e.classid = 'pg_type'::regclass and e.objid = t.oid)

  union all
  select 'collation', quote_ident(n.nspname) || '.' || quote_ident(x.collname)
  from pg_collation x join scope_ns n on n.oid = x.collnamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_collation'::regclass and e.objid = x.oid)

  union all
  select 'conversion', quote_ident(n.nspname) || '.' || quote_ident(x.conname)
  from pg_conversion x join scope_ns n on n.oid = x.connamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_conversion'::regclass and e.objid = x.oid)

  union all
  select 'operator',
         quote_ident(n.nspname) || '.' || x.oprname
           || '(' || coalesce(x.oprleft::regtype::text, 'NONE') || ',' || coalesce(x.oprright::regtype::text, 'NONE') || ')'
  from pg_operator x join scope_ns n on n.oid = x.oprnamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_operator'::regclass and e.objid = x.oid)

  union all
  select 'operator_class', quote_ident(n.nspname) || '.' || quote_ident(x.opcname)
  from pg_opclass x join scope_ns n on n.oid = x.opcnamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_opclass'::regclass and e.objid = x.oid)

  union all
  select 'operator_family', quote_ident(n.nspname) || '.' || quote_ident(x.opfname)
  from pg_opfamily x join scope_ns n on n.oid = x.opfnamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_opfamily'::regclass and e.objid = x.oid)

  union all
  select 'ts_configuration', quote_ident(n.nspname) || '.' || quote_ident(x.cfgname)
  from pg_ts_config x join scope_ns n on n.oid = x.cfgnamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_ts_config'::regclass and e.objid = x.oid)

  union all
  select 'ts_dictionary', quote_ident(n.nspname) || '.' || quote_ident(x.dictname)
  from pg_ts_dict x join scope_ns n on n.oid = x.dictnamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_ts_dict'::regclass and e.objid = x.oid)

  union all
  select 'ts_parser', quote_ident(n.nspname) || '.' || quote_ident(x.prsname)
  from pg_ts_parser x join scope_ns n on n.oid = x.prsnamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_ts_parser'::regclass and e.objid = x.oid)

  union all
  select 'ts_template', quote_ident(n.nspname) || '.' || quote_ident(x.tmplname)
  from pg_ts_template x join scope_ns n on n.oid = x.tmplnamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_ts_template'::regclass and e.objid = x.oid)

  union all
  select 'extended_statistics', quote_ident(n.nspname) || '.' || quote_ident(x.stxname)
  from pg_statistic_ext x join scope_ns n on n.oid = x.stxnamespace
  where not exists (select 1 from ext_members e where e.classid = 'pg_statistic_ext'::regclass and e.objid = x.oid)
)
select class || ':' || name from found order by 1;
