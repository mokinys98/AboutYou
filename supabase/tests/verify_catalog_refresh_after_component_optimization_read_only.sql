-- Run after the controlled catch-up call completes, or after SQL Editor
-- reports an upstream timeout. One row expected. completed_version > 2476
-- and refresh_completed_at after the 19:04 UTC preflight prove a new refresh
-- advanced from the pre-run baseline. Keep cron paused for inspection.
begin read only;
set local statement_timeout = '5s';

select
  clock_timestamp() as checked_at_utc,
  j.active as cron_active,
  s.requested_version,
  s.completed_version,
  s.completed_version > 2476 as advanced_from_baseline,
  s.refresh_completed_at > timestamptz '2026-10-11 19:03:58+00'
    as completed_after_preflight,
  s.requested_version - s.completed_version as version_gap,
  s.last_status,
  s.last_duration_ms,
  s.refresh_started_at,
  s.refresh_completed_at,
  s.last_error,
  ms.n_dead_tup as main_dead_tup_estimate,
  exists (
    select 1 from pg_locks l
    where l.locktype = 'advisory'
      and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted
  ) as refresh_lock_now
from public.catalog_read_model_refresh_state s
cross join cron.job j
join pg_stat_all_tables ms on ms.relid = 'public.catalog_items_read'::regclass
where s.singleton and j.jobname = 'catalog-read-model-refresh';

rollback;
