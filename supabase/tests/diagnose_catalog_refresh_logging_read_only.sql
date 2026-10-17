-- VPS Supabase SQL Editor or codex_reader: inspect the server log settings.
-- Read-only; this does not read
-- log file contents or change logging settings.
begin read only;
set local statement_timeout = '5s';

select
  clock_timestamp() as checked_at_utc,
  current_user as sql_editor_role,
  current_setting('log_destination', true) as log_destination,
  current_setting('logging_collector', true) as logging_collector,
  current_setting('log_min_messages', true) as log_min_messages,
  current_setting('log_line_prefix', true) as log_line_prefix,
  has_function_privilege(current_user, 'pg_catalog.pg_current_logfile()', 'EXECUTE')
    as can_read_current_collector_log_file,
  pg_catalog.pg_current_logfile() as current_collector_log_file;

rollback;
