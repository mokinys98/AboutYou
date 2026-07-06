-- first_seen_at is assigned only when a product is inserted and therefore
-- represents its first appearance in our catalog, unlike updated_at.
create or replace view public.catalog_items with (security_invoker = true) as
select p.id, p.external_id, p.name, p.brand, p.product_url, p.image_urls, p.color_original,
  p.color_family, p.updated_at, s.slug as source,
  o.current_price, o.original_price, o.source_lpl_30, o.observed_min_30d, o.currency,
  (o.observed_min_30d is not null and o.current_price <= o.observed_min_30d) as below_observed_30d,
  case when o.original_price > 0 then round((o.original_price - o.current_price) * 100.0 / o.original_price, 2) else 0 end as discount_pct,
  coalesce(array_agg(distinct c.name) filter (where c.name is not null), '{}') as categories,
  p.sizes, p.other_sizes, p.materials, p.patterns, p.features, p.styles, p.product_types,
  p.color_shade,
  (coalesce(o.source_lpl_30, o.observed_min_30d) is not null and o.current_price <= coalesce(o.source_lpl_30, o.observed_min_30d)) as below_source_lpl_30d,
  p.first_seen_at
from public.products p
join public.sources s on s.id = p.source_id
join public.offers o on o.product_id = p.id
left join public.product_categories pc on pc.product_id = p.id
left join public.categories c on c.id = pc.category_id
where p.active and s.active
group by p.id, s.slug, o.product_id;

create index if not exists products_first_seen_idx
  on public.products (first_seen_at desc, id desc) where active;

-- Keep facet counts scoped to recent products as well.
create or replace function public.catalog_item_matches(
  item public.catalog_items,
  filters jsonb,
  omit_group text default null
) returns boolean language sql stable security invoker set search_path = public as $$
  select
    (omit_group = 'brands' or coalesce(jsonb_array_length(filters->'brands'), 0) = 0 or item.brand in (select jsonb_array_elements_text(filters->'brands'))) and
    (omit_group = 'sources' or coalesce(jsonb_array_length(filters->'sources'), 0) = 0 or item.source in (select jsonb_array_elements_text(filters->'sources'))) and
    (omit_group = 'colors' or coalesce(jsonb_array_length(filters->'colors'), 0) = 0 or item.color_family in (select jsonb_array_elements_text(filters->'colors'))) and
    (omit_group = 'colorShades' or coalesce(jsonb_array_length(filters->'colorShades'), 0) = 0 or item.color_shade in (select jsonb_array_elements_text(filters->'colorShades'))) and
    (omit_group = 'categories' or coalesce(jsonb_array_length(filters->'categories'), 0) = 0 or item.categories && array(select jsonb_array_elements_text(filters->'categories'))) and
    (omit_group = 'sizes' or coalesce(jsonb_array_length(filters->'sizes'), 0) = 0 or item.sizes && array(select jsonb_array_elements_text(filters->'sizes'))) and
    (omit_group = 'otherSizes' or coalesce(jsonb_array_length(filters->'otherSizes'), 0) = 0 or item.other_sizes && array(select jsonb_array_elements_text(filters->'otherSizes'))) and
    (omit_group = 'materials' or coalesce(jsonb_array_length(filters->'materials'), 0) = 0 or item.materials && array(select jsonb_array_elements_text(filters->'materials'))) and
    (omit_group = 'patterns' or coalesce(jsonb_array_length(filters->'patterns'), 0) = 0 or item.patterns && array(select jsonb_array_elements_text(filters->'patterns'))) and
    (omit_group = 'features' or coalesce(jsonb_array_length(filters->'features'), 0) = 0 or item.features && array(select jsonb_array_elements_text(filters->'features'))) and
    (omit_group = 'styles' or coalesce(jsonb_array_length(filters->'styles'), 0) = 0 or item.styles && array(select jsonb_array_elements_text(filters->'styles'))) and
    (omit_group = 'productTypes' or coalesce(jsonb_array_length(filters->'productTypes'), 0) = 0 or item.product_types && array(select jsonb_array_elements_text(filters->'productTypes'))) and
    (omit_group = 'price' or filters->>'priceMin' is null or item.current_price >= (filters->>'priceMin')::integer) and
    (omit_group = 'price' or filters->>'priceMax' is null or item.current_price <= (filters->>'priceMax')::integer) and
    (filters->>'discountMin' is null or item.discount_pct >= (filters->>'discountMin')::numeric) and
    (coalesce((filters->>'belowObserved30d')::boolean, false) = false or
      case when filters->>'priceComparison' = 'source_lpl' then item.below_source_lpl_30d else item.below_observed_30d end) and
    (coalesce((filters->>'newOnly')::boolean, false) = false or item.first_seen_at >= now() - interval '30 days')
$$;

create or replace function public.catalog_news_facets(p_filters jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  with base as materialized (
    select i.*,
      public.catalog_item_matches(i, p_filters, 'brands') as match_brands,
      public.catalog_item_matches(i, p_filters, 'categories') as match_categories,
      public.catalog_item_matches(i, p_filters, 'colors') as match_colors,
      public.catalog_item_matches(i, p_filters, 'colorShades') as match_color_shades,
      public.catalog_item_matches(i, p_filters, 'sources') as match_sources,
      public.catalog_item_matches(i, p_filters, 'sizes') as match_sizes,
      public.catalog_item_matches(i, p_filters, 'otherSizes') as match_other_sizes,
      public.catalog_item_matches(i, p_filters, 'materials') as match_materials,
      public.catalog_item_matches(i, p_filters, 'patterns') as match_patterns,
      public.catalog_item_matches(i, p_filters, 'features') as match_features,
      public.catalog_item_matches(i, p_filters, 'styles') as match_styles,
      public.catalog_item_matches(i, p_filters, 'productTypes') as match_product_types,
      public.catalog_item_matches(i, p_filters, 'price') as match_price
    from public.catalog_items i
    where i.first_seen_at >= now() - interval '30 days'
  )
  select jsonb_build_object(
    'brands', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', brand, 'count', count(*)) x from base where brand <> '' and match_brands group by brand) q),
    'categories', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(categories) value where match_categories group by value) q),
    'colors', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', color_family, 'count', count(*)) x from base where match_colors group by color_family) q),
    'colorShades', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', color_shade, 'count', count(*)) x from base where match_color_shades group by color_shade) q),
    'sources', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', source, 'count', count(*)) x from base where match_sources group by source) q),
    'sizes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(sizes) value where match_sizes group by value) q),
    'otherSizes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(other_sizes) value where match_other_sizes group by value) q),
    'materials', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(materials) value where match_materials group by value) q),
    'patterns', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(patterns) value where match_patterns group by value) q),
    'features', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(features) value where match_features group by value) q),
    'styles', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(styles) value where match_styles group by value) q),
    'productTypes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(product_types) value where match_product_types group by value) q),
    'price', (select jsonb_build_object('min', coalesce(min(current_price), 0), 'max', coalesce(max(current_price), 0)) from base where match_price)
  );
$$;

grant execute on function public.catalog_news_facets(jsonb) to service_role;
