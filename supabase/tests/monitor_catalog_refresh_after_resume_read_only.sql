-- VPS SQL Editor: run after resuming and again after two scheduled 5-minute
-- slots. Compare separate result snapshots after each slot. Expected:
-- job_active=true, completed_version advances, last_error=NULL, and the
-- latest completed refresh lasts <300000 ms. last_status='pending' can be
-- normal when new catalog changes arrive. pg_cron 'succeeded' alone does
-- not prove the refresh function returned status='refreshed'.
begin read only;
set local statement_timeout = '5s';

select
  clock_timestamp() as checked_at_utc,
  j.active as job_active,
  s.requested_version,
  s.completed_version,
  s.requested_version - s.completed_version as version_gap,
  s.last_status,
  s.last_duration_ms,
  s.refresh_started_at,
  s.refresh_completed_at,
  s.last_error,
  ms.n_dead_tup as main_dead_tup_estimate,
  ms.last_autovacuum as main_last_autovacuum,
  exists (
    select 1 from pg_locks l
    where l.locktype = 'advisory'
      and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted
  ) as refresh_lock_now,
  coalesce(r.recent_runs, '[]'::jsonb) as recent_post_recovery_cron_runs
from cron.job j
cross join public.catalog_read_model_refresh_state s
join pg_stat_all_tables ms on ms.relid = 'public.catalog_items_read'::regclass
left join lateral (
  select jsonb_agg(jsonb_build_object(
    'status', runs.status,
    'startedAt', runs.start_time,
    'endedAt', runs.end_time,
    'durationSeconds', extract(epoch from (runs.end_time - runs.start_time)),
    'returnMessage', runs.return_message
  ) order by runs.start_time desc) as recent_runs
  from (
    select status, start_time, end_time, return_message
    from cron.job_run_details
    where jobid = j.jobid
      and start_time > timestamptz '2026-10-11 19:14:57+00'
    order by start_time desc
    limit 5
  ) runs
) r on true
where j.jobname = 'catalog-read-model-refresh'
  and s.singleton;

rollback;
