-- Run in VPS Supabase SQL Editor after applying
-- 20261004180000_stabilize_catalog_category_facet_order.sql.
-- All three booleans should be true. No cache-writing RPC is called.
begin read only;
set local statement_timeout = '45s';

with definitions as (
  select
    pg_get_functiondef('public.catalog_facets(jsonb)'::regprocedure) as original_sql,
    pg_get_functiondef('public.catalog_root_facets()'::regprocedure) as optimized_sql
), comparison as (
  select public.catalog_facets('{}'::jsonb) = public.catalog_root_facets()
    as same_unfiltered_payload
)
select
  position('order by category.level, category.name, category.path' in original_sql) > 0
    as original_has_stable_category_order,
  position('order by category.level, category.name, category.path' in optimized_sql) > 0
    as optimized_has_stable_category_order,
  comparison.same_unfiltered_payload
from definitions cross join comparison;

rollback;
