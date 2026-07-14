-- Persist the expensive catalog join/aggregation for interactive reads.
create materialized view public.catalog_items_read as
select p.id, p.external_id, p.name, p.brand, p.product_url, p.image_urls, p.color_original,
  p.color_family, p.updated_at, s.slug as source,
  o.current_price, o.original_price, o.source_lpl_30, o.observed_min_30d, o.currency,
  (o.observed_min_30d is not null and o.current_price < o.observed_min_30d) as below_observed_30d,
  case
    when o.source_lpl_30 > 0 and o.current_price < o.source_lpl_30
      then round((o.source_lpl_30 - o.current_price) * 100.0 / o.source_lpl_30, 2)
    else 0
  end as discount_pct,
  coalesce(array_agg(distinct category_value) filter (where category_value is not null), '{}') as categories,
  p.sizes, p.other_sizes, p.materials, p.patterns, p.features, p.styles, p.product_types,
  p.color_shade,
  (o.source_lpl_30 is not null and o.current_price < o.source_lpl_30) as below_source_lpl_30d,
  p.first_seen_at,
  coalesce(array_agg(distinct c.name) filter (where c.name is not null), '{}') as category_names,
  coalesce(array_agg(distinct c.path) filter (where c.path is not null), '{}') as category_paths,
  p.is_premium,
  bt.tier as brand_tier
from public.products p
join public.sources s on s.id = p.source_id
join public.offers o on o.product_id = p.id
left join public.product_categories pc on pc.product_id = p.id
left join public.categories c on c.id = pc.category_id
left join lateral (values (c.name), (c.path)) category_values(category_value) on true
left join public.brand_tiers bt
  on bt.brand_key = lower(regexp_replace(trim(p.brand), '\s+', ' ', 'g'))
where p.active and s.active
group by p.id, s.slug, o.product_id, bt.tier;

create unique index catalog_items_read_id_idx on public.catalog_items_read (id);
create index catalog_items_read_updated_idx on public.catalog_items_read (updated_at desc, id desc);
create index catalog_items_read_first_seen_idx on public.catalog_items_read (first_seen_at desc, id desc);
create index catalog_items_read_price_idx on public.catalog_items_read (current_price, id);
create index catalog_items_read_source_lpl_idx on public.catalog_items_read (source_lpl_30, id);
create index catalog_items_read_discount_idx on public.catalog_items_read (discount_pct desc, id desc);
create index catalog_items_read_brand_idx on public.catalog_items_read (brand);
create index catalog_items_read_brand_tier_idx on public.catalog_items_read (brand_tier);
create index catalog_items_read_source_idx on public.catalog_items_read (source);
create index catalog_items_read_color_idx on public.catalog_items_read (color_family);
create index catalog_items_read_color_shade_idx on public.catalog_items_read (color_shade);
create index catalog_items_read_categories_idx on public.catalog_items_read using gin (categories);
create index catalog_items_read_category_paths_idx on public.catalog_items_read using gin (category_paths);
create index catalog_items_read_sizes_idx on public.catalog_items_read using gin (sizes);
create index catalog_items_read_other_sizes_idx on public.catalog_items_read using gin (other_sizes);
create index catalog_items_read_materials_idx on public.catalog_items_read using gin (materials);
create index catalog_items_read_patterns_idx on public.catalog_items_read using gin (patterns);
create index catalog_items_read_features_idx on public.catalog_items_read using gin (features);
create index catalog_items_read_styles_idx on public.catalog_items_read using gin (styles);
create index catalog_items_read_product_types_idx on public.catalog_items_read using gin (product_types);

revoke all on table public.catalog_items_read from public, anon, authenticated;
grant select on table public.catalog_items_read to service_role;

create or replace function public.refresh_catalog_items_read() returns void
language plpgsql security definer set search_path = public as $$
begin
  execute 'refresh materialized view concurrently public.catalog_items_read';
end;
$$;

revoke all on function public.refresh_catalog_items_read() from public, anon, authenticated;
grant execute on function public.refresh_catalog_items_read() to service_role;

-- Build all contextual facets from one compact materialized working set.
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
    select
      i.brand, i.brand_tier, i.categories, i.category_names, i.category_paths,
      i.color_family, i.color_shade, i.source, i.sizes, i.other_sizes, i.materials,
      i.patterns, i.features, i.styles, i.product_types, i.is_premium, i.current_price,
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
  )
  select jsonb_build_object(
    'brands', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', brand, 'count', count(*)) x from base where brand <> '' and failed_groups - (not brand_ok)::integer = 0 group by brand) q),
    'brandTiers', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', brand_tier, 'count', count(*)) x from base where brand_tier is not null and failed_groups - (not brand_tier_ok)::integer = 0 group by brand_tier) q),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', category.id, 'parentId', category.parent_id, 'name', category.name, 'level', category.level, 'path', category.path, 'count', counts.product_count) order by category.level, category.name), '[]'::jsonb) from (select category_path, count(*) as product_count from base cross join lateral unnest(category_paths) category_path where failed_groups - (not category_ok)::integer = 0 group by category_path) counts join public.categories category on category.path = counts.category_path where category.level between 2 and 4 and category.path <> 'vyrams>premium' and counts.product_count > 0),
    'colors', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', color_family, 'count', count(*)) x from base where failed_groups - (not color_ok)::integer = 0 group by color_family) q),
    'colorShades', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', color_shade, 'count', count(*)) x from base where failed_groups - (not color_shade_ok)::integer = 0 group by color_shade) q),
    'sources', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', source, 'count', count(*)) x from base where failed_groups - (not source_ok)::integer = 0 group by source) q),
    'sizes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(sizes) value where failed_groups - (not size_ok)::integer = 0 group by value) q),
    'otherSizes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(other_sizes) value where failed_groups - (not other_size_ok)::integer = 0 group by value) q),
    'materials', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(materials) value where failed_groups - (not material_ok)::integer = 0 group by value) q),
    'patterns', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(patterns) value where failed_groups - (not pattern_ok)::integer = 0 group by value) q),
    'features', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(features) value where failed_groups - (not feature_ok)::integer = 0 group by value) q),
    'styles', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(styles) value where failed_groups - (not style_ok)::integer = 0 group by value) q),
    'productTypes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(product_types) value where failed_groups - (not product_type_ok)::integer = 0 group by value) q),
    'premium', (select jsonb_build_object('count', count(*)) from base where is_premium and failed_groups - (not premium_ok)::integer = 0),
    'price', (select jsonb_build_object('min', coalesce(min(current_price), 0), 'max', coalesce(max(current_price), 0)) from base where failed_groups - (not price_ok)::integer = 0)
  );
$$;

revoke all on function public.catalog_facets(jsonb) from public, anon, authenticated;
grant execute on function public.catalog_facets(jsonb) to service_role;

notify pgrst, 'reload schema';
