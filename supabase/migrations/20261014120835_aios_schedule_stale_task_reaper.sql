create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('aios-reap-stale-tasks', '*/5 * * * *', $$select private.aios_reap_stale_tasks('10 minutes'::interval)$$);
