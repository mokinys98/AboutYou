-- Run after 20261018_resume_catalog_refresh_for_metrics.sql in VPS SQL Editor.
-- Expected: one row, job_active=true, configuration_ok=true,
-- measured_run_ok=true, post_refresh_autovacuum_ok=true.
-- Later scheduled runs may change refresh state and add metrics rows.
begin read only;
set local statement_timeout = '5s';

select
  clock_timestamp() as checked_at_utc,
  j.jobid,
  j.active as job_active,
  j.username = 'postgres'
    and j.database = current_database()
    and j.schedule = '*/5 * * * *'
    and j.command ilike '%set statement_timeout = ''5min''%'
    and j.command ilike '%set lock_timeout = ''3s''%'
    and j.command ilike '%process_catalog_items_read_refresh()%' as configuration_ok,
  exists (
    select 1 from public.catalog_refresh_runs r
    where r.run_id = 1 and r.outcome = 'refreshed'
      and r.duration_ms < 300000 and r.target_version = 3241
      and (select count(*) from public.catalog_refresh_phases p
           where p.run_id = r.run_id and p.outcome = 'success') = 9
  ) as measured_run_ok,
  st.last_autovacuum > r.completed_at and st.n_dead_tup <= 5000
    as post_refresh_autovacuum_ok,
  s.requested_version,
  s.completed_version,
  s.last_status,
  (select count(*) from public.catalog_refresh_runs) as recorded_runs,
  (select count(*) from public.catalog_refresh_phases) as recorded_phases
from cron.job j
cross join public.catalog_read_model_refresh_state s
join public.catalog_refresh_runs r on r.run_id = 1
join pg_stat_all_tables st on st.relid = 'public.catalog_items_read'::regclass
where j.jobname = 'catalog-read-model-refresh' and s.singleton;

rollback;
