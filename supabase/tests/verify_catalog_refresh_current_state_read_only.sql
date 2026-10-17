-- Run in VPS Supabase SQL Editor before another source EXPLAIN ANALYZE.
-- Expected for a quiet diagnostic window: cron_active=false,
-- refresh_run_running=false, refresh_lock_now=false. One row expected.
begin read only;
set local statement_timeout = '5s';

select
  clock_timestamp() as checked_at_utc,
  j.jobid,
  j.jobname,
  j.schedule,
  j.active as cron_active,
  j.command ilike '%process_catalog_items_read_refresh()%' as invokes_refresh,
  exists (
    select 1
    from cron.job_run_details r
    where r.jobid = j.jobid
      and r.status = 'running'
      and r.end_time is null
  ) as refresh_run_running,
  s.requested_version,
  s.completed_version,
  s.requested_version - s.completed_version as version_gap,
  s.last_status,
  s.last_duration_ms,
  s.refresh_started_at,
  s.refresh_completed_at,
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
from cron.job j
cross join public.catalog_read_model_refresh_state s
where j.jobname = 'catalog-read-model-refresh'
  and s.singleton;

rollback;
