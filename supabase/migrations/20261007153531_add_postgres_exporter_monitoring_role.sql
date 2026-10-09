-- Dedicated least-privilege login for prometheus-community/postgres_exporter.
-- The password is deliberately configured separately so no secret enters Git.
DO $role$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = 'supabase_metrics'
  ) THEN
    CREATE ROLE supabase_metrics WITH LOGIN INHERIT CONNECTION LIMIT 5;
  END IF;
END
$role$;

ALTER ROLE supabase_metrics WITH LOGIN INHERIT CONNECTION LIMIT 5;
GRANT CONNECT ON DATABASE postgres TO supabase_metrics;
GRANT pg_monitor TO supabase_metrics;
