-- Run in Supabase SQL Editor after 20261004120000_align_catalog_filter_semantics.sql.
-- Expected: all flags true. These are definition checks; product/count behavior
-- is verified separately with the documented black, LPL and size scenarios.
begin read only;

select
  position('catalog_effective_size_membership_read sf' in pg_get_functiondef('public.catalog_facets(jsonb)'::regprocedure)) > 0 as grouped_sizes_in_facets,
  position('i.source_lpl_30 > 0' in pg_get_functiondef('public.catalog_facets(jsonb)'::regprocedure)) > 0 as lpl_proximity_in_facets,
  position('catalog_effective_size_membership_read' in pg_get_functiondef('public.catalog_item_matches(public.catalog_items_read,jsonb,text)'::regprocedure)) > 0 as effective_sizes_in_alerts,
  position('catalog_facets(cache_filters)' in pg_get_functiondef('public.catalog_facets_cached(jsonb)'::regprocedure)) > 0 as exact_category_path_in_facets,
  position('''{otherSizes}'', ''[]''' in pg_get_functiondef('public.catalog_facets_cached(jsonb)'::regprocedure)) = 0 as other_sizes_not_cleared;

rollback;
