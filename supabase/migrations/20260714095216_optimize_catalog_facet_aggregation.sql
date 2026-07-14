-- Store the already-expanded facet values once. Request-time aggregation can
-- then scan this narrow relation instead of repeatedly unnesting wide rows.
create materialized view public.catalog_item_facet_values_read as
select distinct i.id as product_id, facet.facet_group, value
from public.catalog_items_read i
cross join lateral (values
  ('brands', array[i.brand]::text[]),
  ('brandTiers', array[i.brand_tier::text]::text[]),
  ('categories', i.category_paths),
  ('colors', array[i.color_family]::text[]),
  ('colorShades', array[i.color_shade]::text[]),
  ('sources', array[i.source]::text[]),
  ('sizes', i.sizes),
  ('otherSizes', i.other_sizes),
  ('materials', i.materials),
  ('patterns', i.patterns),
  ('features', i.features),
  ('styles', i.styles),
  ('productTypes', i.product_types)
) facet(facet_group, facet_values)
cross join lateral unnest(facet.facet_values) value
where value is not null and value <> '';

create unique index catalog_item_facet_values_read_unique_idx
  on public.catalog_item_facet_values_read (product_id, facet_group, value);
create index catalog_item_facet_values_read_group_idx
  on public.catalog_item_facet_values_read (facet_group, value, product_id);

revoke all on table public.catalog_item_facet_values_read from public, anon, authenticated;
grant select on table public.catalog_item_facet_values_read to service_role;

create or replace function public.refresh_catalog_items_read() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pg_advisory_xact_lock(hashtext('catalog_items_read_refresh'));
  execute 'refresh materialized view concurrently public.catalog_items_read';
  execute 'refresh materialized view concurrently public.catalog_item_facet_values_read';
end;
$$;

revoke all on function public.refresh_catalog_items_read() from public, anon, authenticated;
grant execute on function public.refresh_catalog_items_read() to service_role;

create or replace function public.catalog_simple_facet(facet_counts jsonb) returns jsonb
language sql immutable security invoker set search_path = public as $$
  select coalesce(facet_counts, '[]'::jsonb);
$$;

revoke all on function public.catalog_simple_facet(jsonb) from public, anon, authenticated;
grant execute on function public.catalog_simple_facet(jsonb) to service_role;

create or replace function public.catalog_facets(p_filters jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  with filter_values as (
    select
      array(select jsonb_array_elements_text(coalesce(p_filters->'brands', '[]'::jsonb))) as brands,
      array(select jsonb_array_elements_text(coalesce(p_filters->'brandTiers', '[]'::jsonb))) as brand_tiers,
      array(select jsonb_array_elements_text(coalesce(p_filters->'categories', '[]'::jsonb))) as categories,
      array(select jsonb_array_elements_text(coalesce(p_filters->'colors', '[]'::jsonb))) as colors,
      array(select jsonb_array_elements_text(coalesce(p_filters->'colorShades', '[]'::jsonb))) as color_shades,
      array(select jsonb_array_elements_text(coalesce(p_filters->'sources', '[]'::jsonb))) as sources,
      array(select jsonb_array_elements_text(coalesce(p_filters->'sizes', '[]'::jsonb))) as sizes,
      array(select jsonb_array_elements_text(coalesce(p_filters->'otherSizes', '[]'::jsonb))) as other_sizes,
      array(select jsonb_array_elements_text(coalesce(p_filters->'materials', '[]'::jsonb))) as materials,
      array(select jsonb_array_elements_text(coalesce(p_filters->'patterns', '[]'::jsonb))) as patterns,
      array(select jsonb_array_elements_text(coalesce(p_filters->'features', '[]'::jsonb))) as features,
      array(select jsonb_array_elements_text(coalesce(p_filters->'styles', '[]'::jsonb))) as styles,
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
  ), checks as materialized (
    select i.id, i.current_price, i.is_premium,
      cardinality(f.brands) = 0 or i.brand = any(f.brands) as brand_ok,
      cardinality(f.brand_tiers) = 0 or i.brand_tier::text = any(f.brand_tiers) as brand_tier_ok,
      cardinality(f.categories) = 0 or i.categories && f.categories as category_ok,
      cardinality(f.colors) = 0 or i.color_family = any(f.colors) as color_ok,
      cardinality(f.color_shades) = 0 or i.color_shade = any(f.color_shades) as color_shade_ok,
      cardinality(f.sources) = 0 or i.source = any(f.sources) as source_ok,
      cardinality(f.sizes) = 0 or i.sizes && f.sizes as size_ok,
      cardinality(f.other_sizes) = 0 or i.other_sizes && f.other_sizes as other_size_ok,
      cardinality(f.materials) = 0 or i.materials && f.materials as material_ok,
      cardinality(f.patterns) = 0 or i.patterns && f.patterns as pattern_ok,
      cardinality(f.features) = 0 or i.features && f.features as feature_ok,
      cardinality(f.styles) = 0 or i.styles && f.styles as style_ok,
      cardinality(f.product_types) = 0 or i.product_types && f.product_types as product_type_ok,
      not f.is_premium or i.is_premium as premium_ok,
      not f.exclude_basics or not (
        i.category_names && public.catalog_excluded_basics_categories() or
        i.categories && public.catalog_excluded_basics_categories()
      ) as basics_ok,
      not f.exclude_accessories or not (i.category_paths && public.catalog_excluded_accessories_paths()) as accessories_ok,
      (f.price_min is null or i.current_price >= f.price_min) and
        (f.price_max is null or i.current_price <= f.price_max) as price_ok,
      (f.discount_min is null or i.discount_pct >= f.discount_min) and
        (not f.below_minimum or case when f.price_comparison = 'source_lpl' then i.below_source_lpl_30d else i.below_observed_30d end) and
        (not f.new_only or i.first_seen_at >= now() - interval '30 days') as common_ok
    from public.catalog_items_read i cross join filter_values f
  ), base as materialized (
    select c.*,
      (not brand_ok)::integer + (not brand_tier_ok)::integer + (not category_ok)::integer +
      (not color_ok)::integer + (not color_shade_ok)::integer + (not source_ok)::integer +
      (not size_ok)::integer + (not other_size_ok)::integer + (not material_ok)::integer +
      (not pattern_ok)::integer + (not feature_ok)::integer + (not style_ok)::integer +
      (not product_type_ok)::integer + (not premium_ok)::integer + (not basics_ok)::integer +
      (not accessories_ok)::integer + (not price_ok)::integer + (not common_ok)::integer as failed_groups
    from checks c
  ), facet_counts as materialized (
    select facet.facet_group, facet.value, count(*) as product_count
    from base
    join public.catalog_item_facet_values_read facet on facet.product_id = base.id
    where base.failed_groups - case facet.facet_group
      when 'brands' then (not base.brand_ok)::integer
      when 'brandTiers' then (not base.brand_tier_ok)::integer
      when 'categories' then (not base.category_ok)::integer
      when 'colors' then (not base.color_ok)::integer
      when 'colorShades' then (not base.color_shade_ok)::integer
      when 'sources' then (not base.source_ok)::integer
      when 'sizes' then (not base.size_ok)::integer
      when 'otherSizes' then (not base.other_size_ok)::integer
      when 'materials' then (not base.material_ok)::integer
      when 'patterns' then (not base.pattern_ok)::integer
      when 'features' then (not base.feature_ok)::integer
      when 'styles' then (not base.style_ok)::integer
      when 'productTypes' then (not base.product_type_ok)::integer
      else 0 end = 0
    group by facet.facet_group, facet.value
  )
  select jsonb_build_object(
    'brands', public.catalog_simple_facet(facet_counts := (select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'brands')),
    'brandTiers', public.catalog_simple_facet(facet_counts := (select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'brandTiers')),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', category.id, 'parentId', category.parent_id, 'name', category.name, 'level', category.level, 'path', category.path, 'count', counts.product_count) order by category.level, category.name), '[]'::jsonb) from facet_counts counts join public.categories category on category.path = counts.value where counts.facet_group = 'categories' and category.level between 2 and 4 and category.path <> 'vyrams>premium' and counts.product_count > 0),
    'colors', public.catalog_simple_facet((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'colors')),
    'colorShades', public.catalog_simple_facet((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'colorShades')),
    'sources', public.catalog_simple_facet((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'sources')),
    'sizes', public.catalog_simple_facet((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'sizes')),
    'otherSizes', public.catalog_simple_facet((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'otherSizes')),
    'materials', public.catalog_simple_facet((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'materials')),
    'patterns', public.catalog_simple_facet((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'patterns')),
    'features', public.catalog_simple_facet((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'features')),
    'styles', public.catalog_simple_facet((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'styles')),
    'productTypes', public.catalog_simple_facet((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'productTypes')),
    'premium', (select jsonb_build_object('count', count(*)) from base where is_premium and failed_groups - (not premium_ok)::integer = 0),
    'price', (select jsonb_build_object('min', coalesce(min(current_price), 0), 'max', coalesce(max(current_price), 0)) from base where failed_groups - (not price_ok)::integer = 0)
  );
$$;

notify pgrst, 'reload schema';
