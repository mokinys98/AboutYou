-- Run in VPS Supabase SQL Editor after applying
-- 20261004170000_fast_unfiltered_catalog_facets.sql. This is read only and
-- compares the new root calculation with the existing unfiltered calculation.
-- It does not call catalog_facets_cached(), which would insert a cache row.
begin read only;
set local statement_timeout = '30s';

with definitions as (
  select
    pg_get_functiondef('public.catalog_root_facets()'::regprocedure) as root_sql,
    pg_get_functiondef('public.catalog_facets_cached(jsonb)'::regprocedure) as cache_sql
), comparison as (
  select public.catalog_root_facets() = public.catalog_facets('{}'::jsonb)
    as same_unfiltered_payload
)
select
  position('from public.catalog_item_facet_values_read' in definitions.root_sql) > 0
    as root_uses_prepared_facets,
  position('when cache_filters = ''{}''::jsonb then public.catalog_root_facets()' in definitions.cache_sql) > 0
    as cache_uses_root_fast_path,
  comparison.same_unfiltered_payload
from definitions cross join comparison;

rollback;
