-- Run in VPS Supabase SQL Editor after applying
-- 20261006100000_prewarm_root_catalog_facets_after_refresh.sql and after a
-- successful catalog refresh. This query does not call the cache-writing RPC.
begin read only;
set local statement_timeout = '15s';

with definition as (
  select lower(pg_get_functiondef(
    'public.invalidate_catalog_facets_cache()'::regprocedure
  )) as sql_body
), cache_row as (
  select payload, created_at
  from public.catalog_facets_cache
  where filters = '{}'::jsonb
), refresh_state as (
  select requested_version, completed_version, last_status, refresh_completed_at
  from public.catalog_read_model_refresh_state
  where singleton
)
select
  position('perform public.catalog_facets_cached(''{}''::jsonb)' in definition.sql_body) > 0
    as refresh_prewarms_root_facets,
  exists (select 1 from cache_row) as root_cache_row_present,
  (select jsonb_typeof(payload) = 'object' from cache_row) as root_payload_is_object,
  (select jsonb_array_length(payload->'categories') > 0 from cache_row)
    as root_payload_has_categories,
  (select created_at from cache_row) as root_cache_created_at,
  (select requested_version = completed_version from refresh_state) as refresh_is_current,
  (select last_status in ('clean', 'refreshed') from refresh_state) as refresh_succeeded,
  (select refresh_completed_at from refresh_state) as refresh_completed_at
from definition;

rollback;
