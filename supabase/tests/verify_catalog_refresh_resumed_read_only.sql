-- Run in SQL Editor after the manual resume script. Expected: one row,
-- active = true, schedule = */5 * * * *, invokes_refresh = true.
begin read only;

select
  clock_timestamp() as checked_at_utc,
  j.jobid,
  j.jobname,
  j.schedule,
  j.active,
  j.command ilike '%process_catalog_items_read_refresh()%' as invokes_refresh,
  s.requested_version,
  s.completed_version,
  s.last_status,
  s.last_duration_ms,
  s.last_error
from cron.job j
cross join public.catalog_read_model_refresh_state s
where j.jobname = 'catalog-read-model-refresh'
  and s.singleton;

rollback;
