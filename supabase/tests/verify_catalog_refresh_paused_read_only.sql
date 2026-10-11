-- Run in SQL Editor after the manual pause script. Expected: one row,
-- active = false, correct schedule and command, no running job or refresh lock.
begin read only;

select
  clock_timestamp() as checked_at_utc,
  j.jobid,
  j.jobname,
  j.schedule,
  j.active,
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
  s.last_status,
  exists (
    select 1
    from pg_locks l
    where l.locktype = 'advisory'
      and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1
      and l.granted
  ) as refresh_advisory_lock_now,
  exists (
    select 1
    from pg_locks l
    where l.relation in (
      'public.catalog_items_read'::regclass,
      'public.catalog_item_facet_values_read'::regclass,
      'public.catalog_size_facets_read'::regclass,
      'public.catalog_effective_size_membership_read'::regclass
    )
      and l.mode in ('ExclusiveLock', 'AccessExclusiveLock')
      and l.granted
  ) as refresh_lock_now
from cron.job j
cross join public.catalog_read_model_refresh_state s
where j.jobname = 'catalog-read-model-refresh'
  and s.singleton;

rollback;
