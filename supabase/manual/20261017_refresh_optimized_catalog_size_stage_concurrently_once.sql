-- One isolated production-like refresh timing on the optimized shadow stage.
-- First run verify_optimized_catalog_size_stage_concurrent_refresh_preflight_read_only.sql.
-- Proceed only if cron_paused=true, refresh_run_running=false,
-- stage_populated=true, stage_indexes_valid=true, and no refresh lock exists.
-- This affects only the shadow stage. It does not alter production views or cron.
-- Run this as one statement in VPS Supabase SQL Editor and record its elapsed time.
-- If SQL Editor returns an upstream/client error, inspect the stage with the
-- separate read-only stage checks and do not retry blindly.
refresh materialized view concurrently public.catalog_size_facets_read_optimized_stage;
