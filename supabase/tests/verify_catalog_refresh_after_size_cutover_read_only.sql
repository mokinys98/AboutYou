-- Run after the controlled post-cutover catch-up, or after an SQL Editor
-- timeout before considering another attempt. Keep cron paused for inspection.
-- Expected: cutover intact, completed_version > 2707, last_status=refreshed,
-- last_duration_ms < 300000, version_gap=0, last_error is null, no locks.
begin read only;
set local statement_timeout = '5s';

select
  clock_timestamp() as checked_at_utc,
  (select count(*) = 1 and bool_and(not j.active)
   from cron.job j
   where j.jobname = 'catalog-read-model-refresh'
     and j.schedule = '*/5 * * * *'
     and j.command ilike '%process_catalog_items_read_refresh()%') as cron_paused,
  s.requested_version,
  s.completed_version,
  s.completed_version > 2707 as advanced_from_cutover_baseline,
  s.requested_version - s.completed_version as version_gap,
  s.last_status,
  s.last_duration_ms,
  s.last_duration_ms < 300000 as completed_under_five_minutes,
  s.last_error,
  s.refresh_started_at,
  s.refresh_completed_at,
  prod.relispopulated as optimized_production_mv_populated,
  backup.relispopulated as rollback_backup_populated,
  has_table_privilege('anon', backup.oid, 'SELECT') as anon_can_read_backup,
  has_table_privilege('authenticated', backup.oid, 'SELECT') as authenticated_can_read_backup,
  has_table_privilege('service_role', backup.oid, 'SELECT') as service_role_can_read_backup,
  exists (
    select 1 from pg_depend d
    join pg_rewrite rw on rw.oid = d.objid
    where rw.ev_class = 'public.catalog_size_facets_read_effective'::regclass
      and d.refobjid = prod.oid
  ) as effective_view_uses_optimized_production_mv,
  exists (
    select 1 from cron.job_run_details r
    join cron.job j on j.jobid = r.jobid
    where j.jobname = 'catalog-read-model-refresh'
      and r.status = 'running' and r.end_time is null
  ) as refresh_run_running,
  exists (
    select 1 from pg_locks l
    where (l.locktype = 'advisory'
      and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted)
      or (l.relation in (
        'public.catalog_items_read'::regclass,
        'public.catalog_item_facet_values_read'::regclass,
        'public.catalog_size_facets_read'::regclass,
        'public.catalog_effective_size_membership_read'::regclass
      ) and l.mode in ('ExclusiveLock', 'AccessExclusiveLock') and l.granted)
  ) as refresh_lock_now
from public.catalog_read_model_refresh_state s
cross join pg_class prod
cross join pg_class backup
where s.singleton
  and prod.oid = 'public.catalog_size_facets_read'::regclass
  and backup.oid = 'public.catalog_size_facets_read_backup_20261017'::regclass;

rollback;
