-- VPS Supabase SQL Editor: bounded history/stats snapshot for the catalog
-- refresh. This is read-only. pg_cron history is retained for about 14 days
-- by the cleanup job. Cron status/return_message do not distinguish a clean
-- function result from a successful heavy refresh; correlate them with phase
-- logs and refresh state instead.
begin read only;
set local statement_timeout = '10s';

with job as (
  select jobid, jobname, schedule, active, username, command
  from cron.job
  where jobname = 'catalog-read-model-refresh'
), recent_runs as (
  select
    r.jobid,
    r.start_time,
    r.end_time,
    r.status,
    r.return_message,
    round(extract(epoch from (r.end_time - r.start_time))::numeric, 3) as duration_seconds
  from cron.job_run_details r
  join job j on j.jobid = r.jobid
  where r.start_time >= clock_timestamp() - interval '14 days'
), run_summary as (
  select
    count(*) as invocations_14d,
    count(*) filter (where status = 'succeeded') as cron_succeeded_14d,
    count(*) filter (where status = 'failed') as cron_failed_14d,
    count(*) filter (where status = 'running' and end_time is null) as cron_running_now,
    min(start_time) as first_run_14d,
    max(start_time) as last_run_14d,
    round(avg(duration_seconds)::numeric, 3) as avg_duration_seconds,
    round(percentile_cont(0.50) within group (order by duration_seconds)::numeric, 3) as p50_duration_seconds,
    round(percentile_cont(0.95) within group (order by duration_seconds)::numeric, 3) as p95_duration_seconds,
    round(max(duration_seconds)::numeric, 3) as max_duration_seconds
  from recent_runs
), recent_run_rows as (
  select coalesce(jsonb_agg(to_jsonb(r) order by r.start_time desc), '[]'::jsonb) as result
  from (select * from recent_runs order by start_time desc limit 60) r
), read_model_stats as (
  select coalesce(jsonb_agg(to_jsonb(s) order by s.total_bytes desc), '[]'::jsonb) as result
  from (
    select
      c.relname,
      c.relkind,
      st.n_live_tup,
      st.n_dead_tup,
      st.n_tup_ins,
      st.n_tup_upd,
      st.n_tup_del,
      st.last_autovacuum,
      st.last_autoanalyze,
      c.reloptions,
      pg_relation_size(c.oid) as heap_bytes,
      pg_indexes_size(c.oid) as index_bytes,
      pg_total_relation_size(c.oid) as total_bytes
    from pg_class c
    left join pg_stat_all_tables st on st.relid = c.oid
    where c.oid in (
      'public.catalog_items_read'::regclass,
      'public.catalog_item_facet_values_read'::regclass,
      'public.catalog_size_facets_read'::regclass,
      'public.catalog_effective_size_membership_read'::regclass,
      'public.catalog_facets_cache'::regclass,
      'public.catalog_static_size_facets_cache'::regclass
    )
  ) s
), statement_stats as (
  select coalesce(jsonb_agg(to_jsonb(s) order by s.total_exec_ms desc), '[]'::jsonb) as result
  from (
    select
      calls,
      rows,
      round(total_exec_time::numeric, 1) as total_exec_ms,
      round(mean_exec_time::numeric, 1) as mean_exec_ms,
      round(max_exec_time::numeric, 1) as max_exec_ms,
      left(query, 300) as query_sample
    from extensions.pg_stat_statements
    where query ilike '%process_catalog_items_read_refresh%'
       or query ilike '%refresh materialized view%catalog_%'
    order by total_exec_time desc
    limit 30
  ) s
), phase_logging as (
  select coalesce(jsonb_agg(to_jsonb(p) order by p.function_name), '[]'::jsonb) as result
  from (
    select
      p.oid::regprocedure::text as function_name,
      pg_get_userbyid(p.proowner) as owner,
      position('catalog_refresh_phase' in pg_get_functiondef(p.oid)) > 0 as emits_phase_logs,
      position('catalog_refresh_run' in pg_get_functiondef(p.oid)) > 0 as emits_run_logs
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'process_catalog_items_read_refresh',
        'rebuild_catalog_items_read_internal',
        'invalidate_catalog_facets_cache'
      )
  ) p
)
select
  clock_timestamp() as checked_at_utc,
  (select jsonb_agg(to_jsonb(j)) from job j) as cron_job,
  to_jsonb(rs) as cron_run_summary_14d,
  rr.result as latest_cron_runs,
  (select jsonb_build_object(
    'requested_version', s.requested_version,
    'completed_version', s.completed_version,
    'version_gap', s.requested_version - s.completed_version,
    'last_status', s.last_status,
    'last_duration_ms', s.last_duration_ms,
    'last_error', s.last_error,
    'requested_at', s.requested_at,
    'refresh_started_at', s.refresh_started_at,
    'refresh_completed_at', s.refresh_completed_at
  ) from public.catalog_read_model_refresh_state s where s.singleton) as latest_refresh_state,
  rms.result as read_model_stats,
  ss.result as pg_stat_statements,
  pl.result as phase_logging_installed
from run_summary rs
cross join recent_run_rows rr
cross join read_model_stats rms
cross join statement_stats ss
cross join phase_logging pl;

rollback;
