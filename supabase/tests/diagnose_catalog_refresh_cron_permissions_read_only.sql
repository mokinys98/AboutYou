-- Run this whole file in VPS Supabase SQL Editor after the 42501 pause error.
-- Every statement is read-only. Share all result grids and any error.
begin read only;

select
  current_user as sql_editor_role,
  session_user as login_role,
  current_setting('transaction_read_only') as transaction_read_only,
  e.extversion as pg_cron_version,
  pg_get_userbyid(c.relowner) as cron_job_table_owner,
  has_schema_privilege(current_user, n.oid, 'USAGE') as can_use_cron_schema,
  has_table_privilege(current_user, c.oid, 'SELECT') as can_select_cron_job,
  has_table_privilege(current_user, c.oid, 'UPDATE') as can_update_cron_job
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_extension e on e.extname = 'pg_cron'
where n.nspname = 'cron' and c.relname = 'job';

select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  pg_get_userbyid(p.proowner) as function_owner,
  has_function_privilege(current_user, p.oid, 'EXECUTE') as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'cron' and p.proname = 'alter_job';

select
  jobid, jobname, schedule, command, username as job_run_as,
  database, active
from cron.job
where jobname = 'catalog-read-model-refresh'
order by jobid;

rollback;
