-- Run in Supabase SQL Editor after 20261004110000_materialize_catalog_effective_sizes.sql.
-- Expected: all four flags true and sample_mismatches = 0.
begin read only;

select
  to_regclass('public.catalog_effective_size_membership_read') is not null as model_exists,
  to_regclass('public.catalog_effective_size_membership_read_product_token_idx') is not null as unique_index_exists,
  position('catalog_effective_size_membership_read' in pg_get_functiondef('public.catalog_build_contextual_size_facets(jsonb)'::regprocedure)) > 0 as builder_uses_model,
  position('refresh materialized view concurrently public.catalog_effective_size_membership_read' in pg_get_functiondef('public.invalidate_catalog_facets_cache()'::regprocedure)) > 0 as invalidation_refreshes_model;

with sample_ids as (
  select distinct product_id
  from public.catalog_effective_size_membership_read
  order by product_id
  limit 20
), expected as (
  select distinct sf.product_id, sf.token
  from public.catalog_size_facets_read_effective sf
  join sample_ids s on s.product_id = sf.product_id
), actual as (
  select m.product_id, m.token
  from public.catalog_effective_size_membership_read m
  join sample_ids s on s.product_id = m.product_id
), mismatches as (
  (select * from expected except select * from actual)
  union all
  (select * from actual except select * from expected)
)
select count(*) as sample_mismatches from mismatches;

rollback;
