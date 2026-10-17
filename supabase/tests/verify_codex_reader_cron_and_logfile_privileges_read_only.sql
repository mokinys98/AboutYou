-- Run in the VPS Supabase SQL Editor after applying the relevant grants.
-- This inspects effective privileges and does not change data or permissions.
begin read only;

select
  has_schema_privilege('codex_reader', n.oid, 'USAGE') as cron_schema_usage,
  has_table_privilege('codex_reader', j.oid, 'SELECT') as cron_job_select,
  has_table_privilege('codex_reader', r.oid, 'SELECT') as cron_job_run_details_select,
  has_function_privilege('codex_reader', f.oid, 'EXECUTE') as pg_current_logfile_execute
from pg_namespace n
join pg_class j on j.relnamespace = n.oid and j.relname = 'job'
join pg_class r on r.relnamespace = n.oid and r.relname = 'job_run_details'
cross join pg_proc f
join pg_namespace fn on fn.oid = f.pronamespace
where n.nspname = 'cron'
  and fn.nspname = 'pg_catalog'
  and f.proname = 'pg_current_logfile'
  and f.pronargs = 0;

rollback;
