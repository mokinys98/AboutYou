-- Run in VPS Supabase SQL Editor after applying
-- 20261004150000_label_catalog_refresh_failure_phase.sql. This does not start
-- a refresh. Both instrumentation flags should be true immediately. A later
-- failed cron cycle should include "catalog refresh phase" in last_error.
begin read only;

with definitions as (
  select
    pg_get_functiondef('public.rebuild_catalog_items_read_internal()'::regprocedure) as rebuild_sql,
    pg_get_functiondef('public.invalidate_catalog_facets_cache()'::regprocedure) as invalidate_sql
), state as (
  select requested_version, completed_version, last_status,
    last_duration_ms, last_error, refresh_started_at, refresh_completed_at
  from public.catalog_read_model_refresh_state
  where singleton
)
select
  position('catalog refresh phase' in definitions.rebuild_sql) > 0 as rebuild_phase_installed,
  position('catalog refresh phase' in definitions.invalidate_sql) > 0 as invalidate_phase_installed,
  position('refresh materialized view public.catalog_effective_size_membership_read' in lower(definitions.invalidate_sql)) > 0
    as full_effective_refresh_retained,
  state.requested_version,
  state.completed_version,
  state.last_status,
  state.last_duration_ms,
  state.last_error,
  state.refresh_started_at,
  state.refresh_completed_at
from definitions cross join state;

rollback;
