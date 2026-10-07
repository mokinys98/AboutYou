-- Allow the dedicated exporter login to resolve pg_stat_statements in the
-- extensions schema. Scope the search_path setting to the postgres database.
GRANT USAGE ON SCHEMA extensions TO supabase_metrics;

ALTER ROLE supabase_metrics IN DATABASE postgres
  SET search_path = 'extensions, pg_catalog';
