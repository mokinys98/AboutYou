-- Run after the migration and after at least one requested refresh cycle.
-- Expected: all structure flags true, catalog_current true, last_error null,
-- last_status refreshed or clean, last_duration_ms below 300000 for a refresh.
-- A clean status may retain the last successful refresh duration.
begin read only;

with definition as (
  select lower(pg_get_functiondef('public.invalidate_catalog_facets_cache()'::regprocedure)) as body
), state as (
  select requested_version, completed_version, last_status,
    last_duration_ms, last_error, refresh_started_at, refresh_completed_at
  from public.catalog_read_model_refresh_state
  where singleton
), index_check as (
  select exists (
    select 1 from pg_index i
    join pg_class c on c.oid = i.indrelid
    where i.indrelid = 'public.catalog_effective_size_membership_read'::regclass
      and c.relispopulated
      and i.indexrelid = 'public.catalog_effective_size_membership_read_product_token_idx'::regclass
      and i.indisunique and i.indisvalid and i.indisready
      and i.indpred is null and i.indexprs is null
  ) as concurrent_index_ready
)
select
  clock_timestamp() as checked_at_utc,
  position('refresh materialized view concurrently public.catalog_effective_size_membership_read' in definition.body) > 0
    as concurrent_refresh_installed,
  position('from public.catalog_effective_size_membership_read sf' in definition.body) > 0
    as fast_static_dictionary_retained,
  position('perform public.refresh_catalog_static_size_facets_cache()' in definition.body) = 0
    as slow_static_rebuild_absent,
  index_check.concurrent_index_ready,
  state.requested_version,
  state.completed_version,
  state.requested_version = state.completed_version as catalog_current,
  state.last_status,
  state.last_duration_ms,
  state.last_error,
  state.refresh_started_at,
  state.refresh_completed_at,
  exists (
    select 1 from pg_locks l
    where l.relation = 'public.catalog_effective_size_membership_read'::regclass
      and l.mode = 'AccessExclusiveLock' and l.granted
  ) as access_exclusive_lock_now
from definition cross join state cross join index_check;

rollback;
