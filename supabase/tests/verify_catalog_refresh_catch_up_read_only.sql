-- Run after the one-time catch-up. Baseline completed_version was 2476.
-- Expected: last_status='refreshed', completed_version > 2476,
-- one_call_advanced_from_baseline=true, no refresh lock. Also inspect the
-- catch_up_result JSON from the manual script: status must be 'refreshed'.
-- requested_version may increase during the run; inspect any remaining gap
-- before cron resumes.
begin read only;

select
  clock_timestamp() as checked_at_utc,
  j.active as refresh_job_active,
  s.requested_version,
  s.completed_version,
  (s.last_status = 'refreshed' and s.completed_version > 2476)
    as one_call_advanced_from_baseline,
  s.requested_version - s.completed_version as version_gap,
  s.last_status,
  s.last_duration_ms,
  s.refresh_started_at,
  s.refresh_completed_at,
  s.last_error,
  pg_size_pretty(pg_relation_size('public.catalog_items_read'::regclass)) as main_heap,
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
