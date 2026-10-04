-- Run in VPS Supabase SQL Editor after applying
-- 20261004140000_unblock_effective_size_refresh.sql. This does not trigger a
-- refresh. The function check should be true immediately; the state should
-- become current after the next scheduled successful cron run.
begin read only;

with definition as (
  select lower(pg_get_functiondef('public.invalidate_catalog_facets_cache()'::regprocedure)) as sql_body
), state as (
  select requested_version, completed_version, last_status,
    last_duration_ms, last_error, refresh_started_at, refresh_completed_at
  from public.catalog_read_model_refresh_state
  where singleton
)
select
  position('refresh materialized view public.catalog_effective_size_membership_read' in definition.sql_body) > 0
    as full_refresh_installed,
  position('refresh materialized view concurrently public.catalog_effective_size_membership_read' in definition.sql_body) = 0
    as concurrent_refresh_removed,
  state.requested_version,
  state.completed_version,
  state.requested_version = state.completed_version as catalog_current,
  state.last_status,
  state.last_duration_ms,
  state.last_error,
  state.refresh_started_at,
  state.refresh_completed_at
from definition cross join state;

rollback;
