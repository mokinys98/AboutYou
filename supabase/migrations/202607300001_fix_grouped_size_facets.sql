-- Fix contextual grouped-size aggregation for databases where
-- 202607290001_group_catalog_size_facets.sql is already applied.

create or replace function public.catalog_grouped_size_facets(p_filters jsonb default '{}'::jsonb)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp as $$
  with filter_values as (
    select
      array(select jsonb_array_elements_text(coalesce(p_filters->'brands', '[]'::jsonb))) as brands,
      array(select jsonb_array_elements_text(coalesce(p_filters->'brandTiers', '[]'::jsonb))) as brand_tiers,
      array(select jsonb_array_elements_text(coalesce(p_filters->'categories', '[]'::jsonb))) as categories,
      array(select jsonb_array_elements_text(coalesce(p_filters->'colors', '[]'::jsonb))) as colors,
      array(select jsonb_array_elements_text(coalesce(p_filters->'colorShades', '[]'::jsonb))) as color_shades,
      array(select jsonb_array_elements_text(coalesce(p_filters->'sources', '[]'::jsonb))) as sources,
      array(select jsonb_array_elements_text(coalesce(p_filters->'productTypes', '[]'::jsonb))) as product_types,
      coalesce((p_filters->>'isPremium')::boolean, false) as is_premium,
      coalesce((p_filters->>'excludeBasics')::boolean, false) as exclude_basics,
      coalesce((p_filters->>'excludeAccessories')::boolean, false) as exclude_accessories,
      coalesce((p_filters->>'newOnly')::boolean, false) as new_only,
      nullif(p_filters->>'priceMin', '')::integer as price_min,
      nullif(p_filters->>'priceMax', '')::integer as price_max,
      nullif(p_filters->>'discountMin', '')::numeric as discount_min,
      coalesce((p_filters->>'belowObserved30d')::boolean, false) as below_minimum,
      coalesce(p_filters->>'priceComparison', 'observed') as price_comparison
  ), matching_products as (
    select i.id
    from public.catalog_items_read i
    cross join filter_values f
    where
      (cardinality(f.brands) = 0 or i.brand = any(f.brands)) and
      (cardinality(f.brand_tiers) = 0 or i.brand_tier::text = any(f.brand_tiers)) and
      (cardinality(f.categories) = 0 or i.categories && f.categories) and
      (cardinality(f.colors) = 0 or i.color_family = any(f.colors)) and
      (cardinality(f.color_shades) = 0 or i.color_shade = any(f.color_shades)) and
      (cardinality(f.sources) = 0 or i.source = any(f.sources)) and
      (cardinality(f.product_types) = 0 or i.product_types && f.product_types) and
      (not f.is_premium or i.is_premium) and
      (not f.exclude_basics or not (i.category_names && public.catalog_excluded_basics_categories() or i.categories && public.catalog_excluded_basics_categories())) and
      (not f.exclude_accessories or not (i.category_paths && public.catalog_excluded_accessories_paths())) and
      (f.price_min is null or i.current_price >= f.price_min) and
      (f.price_max is null or i.current_price <= f.price_max) and
      (f.discount_min is null or i.discount_pct >= f.discount_min) and
      (not f.below_minimum or case when f.price_comparison = 'source_lpl' then i.below_source_lpl_30d else i.below_observed_30d end) and
      (not f.new_only or i.first_seen_at >= now() - interval '30 days')
  ), grouped as (
    select sf.domain_key, sf.domain_label, sf.value_key, sf.display_label, sf.token,
      min(sf.sort_order) as sort_order, count(distinct sf.product_id) as product_count
    from public.catalog_size_facets_read sf
    join matching_products mp on mp.id = sf.product_id
    group by sf.domain_key, sf.domain_label, sf.value_key, sf.display_label, sf.token
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'value', grouped.token,
    'label', grouped.display_label,
    'domainKey', grouped.domain_key,
    'domainLabel', grouped.domain_label,
    'valueKey', grouped.value_key,
    'sortOrder', grouped.sort_order,
    'count', grouped.product_count
  ) order by grouped.domain_key, grouped.sort_order, grouped.display_label), '[]'::jsonb)
  from grouped;
$$;

delete from public.catalog_facets_cache;
select public.catalog_facets_cached('{}'::jsonb);

notify pgrst, 'reload schema';
