-- Run before 20261005090000_nonblocking_effective_size_refresh.sql.
-- This is one bounded, read-only row for SQL Editor or the authorized tunnel.
-- If run after migration, full_refresh_installed = false is expected;
-- use verify_nonblocking_effective_size_refresh_read_only.sql for post-check.
begin read only;

with definition as (
  select lower(pg_get_functiondef(p.oid)) as body,
    pg_get_userbyid(p.proowner) as function_owner
  from pg_proc p
  where p.oid = 'public.invalidate_catalog_facets_cache()'::regprocedure
), state as (
  select requested_version, completed_version, last_status,
    last_duration_ms, last_error, refresh_started_at, refresh_completed_at
  from public.catalog_read_model_refresh_state
  where singleton
)
select
  clock_timestamp() as checked_at_utc,
  definition.function_owner,
  position('refresh materialized view public.catalog_effective_size_membership_read' in definition.body) > 0
    as full_refresh_installed,
  position('from public.catalog_effective_size_membership_read sf' in definition.body) > 0
    as fast_static_dictionary_installed,
  exists (
    select 1 from pg_index i
    join pg_class c on c.oid = i.indrelid
    where i.indrelid = 'public.catalog_effective_size_membership_read'::regclass
      and c.relispopulated
      and i.indexrelid = 'public.catalog_effective_size_membership_read_product_token_idx'::regclass
      and i.indisunique and i.indisvalid and i.indisready
      and i.indpred is null and i.indexprs is null
  ) as concurrent_index_ready,
  pg_total_relation_size('public.catalog_effective_size_membership_read'::regclass)
    as membership_bytes,
  state.requested_version,
  state.completed_version,
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
from definition cross join state;

rollback;
