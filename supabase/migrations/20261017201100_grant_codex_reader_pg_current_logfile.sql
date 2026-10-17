-- Owner-only handoff. On this VPS pg_catalog.pg_current_logfile() is owned by
-- supabase_admin; the SQL Editor's postgres role lacks EXECUTE WITH GRANT OPTION.
-- Do not run this as postgres: the owner (or a superuser) must run it in SQL Editor.
begin;

grant execute on function pg_catalog.pg_current_logfile() to codex_reader;

commit;
