-- Run in VPS Supabase SQL Editor. This reads cron status and the recent refresh
-- failures without starting, changing, or retrying any job.
begin read only;

select jobid, jobname, schedule, active, command
from cron.job
where jobname = 'catalog-read-model-refresh';

select
  details.start_time,
  details.end_time,
  details.status,
  details.return_message
from cron.job_run_details details
join cron.job job on job.jobid = details.jobid
where job.jobname = 'catalog-read-model-refresh'
order by details.start_time desc
limit 12;

select
  calls,
  round(total_exec_time::numeric, 1) as total_exec_ms,
  round(max_exec_time::numeric, 1) as max_exec_ms,
  left(query, 240) as query_prefix
from extensions.pg_stat_statements
where query ilike '%catalog_effective_size_membership_read%'
  and query not ilike '%pg_stat_statements%'
order by max_exec_time desc
limit 10;

rollback;
