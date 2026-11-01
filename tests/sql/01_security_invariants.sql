-- Fails (raises) on any violated invariant. Run against a database built from supabase/migrations only.
do $$
declare v text;
begin
  -- 1. RLS enabled on every public aios_* table
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind='r' and c.relname like 'aios\_%' and not c.relrowsecurity;
  if v is not null then raise exception 'RLS disabled on: %', v; end if;

  -- 2. Every SECURITY DEFINER function in public/private pins search_path
  select string_agg(n.nspname||'.'||p.proname, ', ') into v from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('public','private') and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%');
  if v is not null then raise exception 'SECURITY DEFINER without pinned search_path: %', v; end if;

  -- 3. anon/authenticated cannot execute private.aios_* maintenance or kernel functions
  select string_agg(p.proname, ', ') into v from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='private' and p.proname like 'aios\_%'
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
     and p.proname not in ('aios_is_org_member','aios_is_org_admin');
  if v is not null then raise exception 'client roles can execute private functions: %', v; end if;

  -- 4. Maintenance jobs: exactly one active schedule each, no duplicates
  if (select count(*) from cron.job where jobname='aios-reap-stale-tasks' and active) <> 1 then raise exception 'reaper schedule missing or duplicated'; end if;
  if (select count(*) from cron.job where jobname='aios-expire-stale-approvals' and active) <> 1 then raise exception 'approval expiry schedule missing or duplicated'; end if;

  -- 5. No duplicate indexes on aios_* tables (same table, key columns, predicate)
  select string_agg(a.indexrelid::regclass::text||' ~ '||b.indexrelid::regclass::text, '; ') into v
    from pg_index a join pg_index b on a.indrelid=b.indrelid and a.indexrelid<b.indexrelid and a.indkey=b.indkey
     and a.indisunique=b.indisunique and coalesce(pg_get_expr(a.indpred,a.indrelid),'')=coalesce(pg_get_expr(b.indpred,b.indrelid),'')
    join pg_class c on c.oid=a.indrelid where c.relname like 'aios\_%';
  if v is not null then raise exception 'duplicate indexes: %', v; end if;

  -- 6. Disposition table is append-only
  begin
    update public.aios_backlog_dispositions set rationale = rationale where false;
  exception when others then null;
  end;
  if not exists (select 1 from pg_trigger where tgname='trg_aios_backlog_dispositions_immutable') then raise exception 'disposition immutability trigger missing'; end if;

  -- 7. Convergence function runs and returns its report shape on an empty or populated database
  if (private.aios_expire_stale_approvals()) ? 'skipped_in_flight' is not true then raise exception 'expiry function report shape wrong'; end if;
  -- 8. After convergence no legacy pending approval (NULL expires_at, >24h) with a non-in-flight invocation may remain
  if exists (select 1 from public.aios_approvals ap where ap.status='pending' and ap.expires_at is null and ap.created_at < now()-interval '24 hours'
             and not exists (select 1 from public.aios_tool_invocations i where i.approval_id=ap.id and i.status<>'requires_approval')) then
    raise exception 'legacy pending approvals remain after convergence';
  end if;
end $$;
select 'ok: security invariants' as result;
