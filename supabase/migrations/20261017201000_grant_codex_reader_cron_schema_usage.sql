-- Apply manually in the VPS Supabase SQL Editor as postgres.
-- cron.job and cron.job_run_details already grant SELECT to PUBLIC on this VPS.
-- USAGE also exposes cron routines for which this role already has EXECUTE.
begin;

grant usage on schema cron to codex_reader;

commit;
