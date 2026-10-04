-- Run in VPS Supabase SQL Editor. A single result set contains all sections,
-- since SQL Editor may display only the final SELECT from a script.
-- Reads cron status and recent refresh failures without changing any job.
begin read only;

with job as (
  select jobid, jobname, schedule, active, command
  from cron.job
  where jobname = 'catalog-read-model-refresh'
), recent_runs as (
  select details.start_time, details.end_time, details.status,
    details.return_message
  from cron.job_run_details details
  join job on job.jobid = details.jobid
  order by details.start_time desc
  limit 12
), statements as (
  select calls,
    round(total_exec_time::numeric, 1) as total_exec_ms,
    round(max_exec_time::numeric, 1) as max_exec_ms,
    left(query, 240) as query_prefix
  from extensions.pg_stat_statements
  where query ilike '%catalog_effective_size_membership_read%'
    and query not ilike '%pg_stat_statements%'
  order by max_exec_time desc
  limit 10
)
select 'cron_job' as section,
  coalesce((select jsonb_agg(to_jsonb(j) order by j.jobid) from job j), '[]'::jsonb) as result
union all
select 'recent_runs',
  coalesce((select jsonb_agg(to_jsonb(r) order by r.start_time desc) from recent_runs r), '[]'::jsonb)
union all
select 'statement_samples',
  coalesce((select jsonb_agg(to_jsonb(s) order by s.max_exec_ms desc) from statements s), '[]'::jsonb);

rollback;
