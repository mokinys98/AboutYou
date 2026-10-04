-- Apply after 20261004110000_materialize_catalog_effective_sizes.sql.
-- Keep product listing, facets and alert predicates on the same effective
-- membership and apply the same common LPL proximity filter.
begin;

-- Apply predicates shared by every facet before joining the expanded facet
-- read model. These predicates are never self-excluded, so their early
-- application preserves facet counts while reducing the rows that reach the
-- 2M+ value relation for contexts such as below-LPL.
--
-- Keep this function body aligned with the existing facet contract. Per-group
-- filters remain in failed_groups and are still excluded only for their own
-- facet group.
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
      nullif(p_filters->>'lplProximityPct', '')::numeric as lpl_proximity_pct,
      coalesce((p_filters->>'belowObserved30d')::boolean, false) as below_minimum,
      coalesce(p_filters->>'priceComparison', 'observed') as price_comparison
  ), checks as materialized (
    select i.id, i.current_price, i.is_premium,
      cardinality(f.brands) = 0 or i.brand = any(f.brands) as brand_ok,
      cardinality(f.brand_tiers) = 0 or i.brand_tier::text = any(f.brand_tiers) as brand_tier_ok,
      cardinality(f.categories) = 0 or i.category_paths && f.categories or i.categories && f.categories as category_ok,
      cardinality(f.colors) = 0 or i.color_family = any(f.colors) as color_ok,
      cardinality(f.color_shades) = 0 or i.color_shade = any(f.color_shades) as color_shade_ok,
      cardinality(f.sources) = 0 or i.source = any(f.sources) as source_ok,
      cardinality(f.sizes) = 0 or i.sizes && f.sizes or exists (
        select 1 from public.catalog_effective_size_membership_read sf
        where sf.product_id = i.id and sf.token = any(f.sizes)
      ) as size_ok,
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
        (f.lpl_proximity_pct is null or (i.source_lpl_30 > 0 and i.current_price * 100.0 / i.source_lpl_30 <= 100 + f.lpl_proximity_pct)) and
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
      (not accessories_ok)::integer + (not price_ok)::integer as failed_groups
    from checks c
    -- Common predicates never participate in facet self-exclusion, so discard
    -- non-matching products before expanding the facet-value read model.
    where c.common_ok
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

create or replace function public.catalog_facets_cached(
  p_filters jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  result jsonb;
  cache_filters jsonb := coalesce(p_filters, '{}'::jsonb);
begin
  if
    coalesce(jsonb_array_length(cache_filters->'brands'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'brandTiers'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'sources'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'categories'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'colors'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'colorShades'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'sizes'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'otherSizes'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'materials'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'patterns'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'features'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'styles'), 0) = 0 and
    coalesce(jsonb_array_length(cache_filters->'productTypes'), 0) = 0 and
    coalesce((cache_filters->>'isPremium')::boolean, false) = false and
    coalesce((cache_filters->>'excludeBasics')::boolean, false) = false and
    coalesce((cache_filters->>'excludeAccessories')::boolean, false) = false and
    coalesce((cache_filters->>'belowObserved30d')::boolean, false) = false and
    coalesce((cache_filters->>'newOnly')::boolean, false) = false and
    nullif(cache_filters->>'categoryPath', '') is null and
    nullif(cache_filters->>'priceMin', '') is null and
    nullif(cache_filters->>'priceMax', '') is null and
    nullif(cache_filters->>'discountMin', '') is null and
    nullif(cache_filters->>'lplProximityPct', '') is null
  then
    cache_filters := '{}'::jsonb;
  end if;

  select payload into result
  from public.catalog_facets_cache
  where filters = cache_filters;

  if found then
    return result;
  end if;

  result := public.catalog_facets(cache_filters);
  result := jsonb_set(
    result,
    '{sizes}',
    public.catalog_grouped_size_facets(cache_filters),
    true
  );

  insert into public.catalog_facets_cache(filters, payload)
  values (cache_filters, result)
  on conflict (filters) do update
  set payload = excluded.payload,
      created_at = now();

  return result;
end;
$$;

revoke all on function public.catalog_facets_cached(jsonb)
  from public, anon, authenticated;
grant execute on function public.catalog_facets_cached(jsonb)
  to service_role;

-- Contextual grouped sizes ignore their own size selection, but respect
-- the independent otherSizes filter.
create or replace function public.catalog_build_contextual_size_facets(
  p_filters jsonb
) returns jsonb
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
      nullif(p_filters->>'lplProximityPct', '')::numeric as lpl_proximity_pct,
      coalesce((p_filters->>'belowObserved30d')::boolean, false) as below_minimum,
      coalesce(p_filters->>'priceComparison', 'observed') as price_comparison
  ), matching_products as materialized (
    select i.id
    from public.catalog_items_read_with_lpl i
    cross join filter_values f
    where
      (cardinality(f.brands) = 0 or i.brand = any(f.brands)) and
      (cardinality(f.brand_tiers) = 0 or i.brand_tier::text = any(f.brand_tiers)) and
      (cardinality(f.categories) = 0 or (
        i.category_paths && f.categories or i.categories && f.categories
      )) and
      (cardinality(f.colors) = 0 or i.color_family = any(f.colors)) and
      (cardinality(f.color_shades) = 0 or i.color_shade = any(f.color_shades)) and
      (cardinality(f.sources) = 0 or i.source = any(f.sources)) and
      (cardinality(f.other_sizes) = 0 or i.other_sizes && f.other_sizes) and
      (cardinality(f.materials) = 0 or i.materials && f.materials) and
      (cardinality(f.patterns) = 0 or i.patterns && f.patterns) and
      (cardinality(f.features) = 0 or i.features && f.features) and
      (cardinality(f.styles) = 0 or i.styles && f.styles) and
      (cardinality(f.product_types) = 0 or i.product_types && f.product_types) and
      (not f.is_premium or i.is_premium) and
      (not f.exclude_basics or not (
        i.category_names && public.catalog_excluded_basics_categories() or
        i.categories && public.catalog_excluded_basics_categories()
      )) and
      (not f.exclude_accessories or not (i.category_paths && public.catalog_excluded_accessories_paths())) and
      (f.price_min is null or i.current_price >= f.price_min) and
      (f.price_max is null or i.current_price <= f.price_max) and
      (f.discount_min is null or i.discount_pct >= f.discount_min) and
      (f.lpl_proximity_pct is null or i.lpl_price_ratio <= 100 + f.lpl_proximity_pct) and
      (not f.below_minimum or case
        when f.price_comparison = 'source_lpl' then i.below_source_lpl_30d
        else i.below_observed_30d
      end) and
      (not f.new_only or i.first_seen_at >= now() - interval '30 days')
  ), grouped as (
    select
      sf.domain_key,
      max(sf.domain_label) as domain_label,
      sf.value_key,
      max(sf.display_label) as display_label,
      sf.token,
      min(sf.sort_order) as sort_order,
      count(distinct sf.product_id) as product_count
    from matching_products product
    join public.catalog_effective_size_membership_read sf
      on sf.product_id = product.id
    group by sf.domain_key, sf.value_key, sf.token
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
  from grouped
  where grouped.product_count > 0;
$$;

revoke all on function public.catalog_build_contextual_size_facets(jsonb)
  from public, anon, authenticated;

create or replace function public.catalog_item_matches(
  item public.catalog_items_read,
  filters jsonb,
  omit_group text default null
) returns boolean
language sql stable security invoker set search_path = public, pg_temp as $$
  select
    (omit_group = 'brands' or coalesce(jsonb_array_length(filters->'brands'), 0) = 0 or item.brand in (select jsonb_array_elements_text(filters->'brands'))) and
    (omit_group = 'brandTiers' or coalesce(jsonb_array_length(filters->'brandTiers'), 0) = 0 or item.brand_tier in (select jsonb_array_elements_text(filters->'brandTiers'))) and
    (omit_group = 'sources' or coalesce(jsonb_array_length(filters->'sources'), 0) = 0 or item.source in (select jsonb_array_elements_text(filters->'sources'))) and
    (omit_group = 'colors' or coalesce(jsonb_array_length(filters->'colors'), 0) = 0 or item.color_family in (select jsonb_array_elements_text(filters->'colors'))) and
    (omit_group = 'colorShades' or coalesce(jsonb_array_length(filters->'colorShades'), 0) = 0 or item.color_shade in (select jsonb_array_elements_text(filters->'colorShades'))) and
    (omit_group = 'categories' or case when nullif(filters->>'categoryPath', '') is not null then nullif(filters->>'categoryPath', '') = any(item.category_paths) else coalesce(jsonb_array_length(filters->'categories'), 0) = 0 or item.categories && array(select jsonb_array_elements_text(coalesce(filters->'categories', '[]'::jsonb))) or item.category_paths && array(select jsonb_array_elements_text(coalesce(filters->'categories', '[]'::jsonb))) end) and
    (omit_group = 'sizes' or coalesce(jsonb_array_length(filters->'sizes'), 0) = 0 or
      ((item.sizes && array(select sizes.value from jsonb_array_elements_text(filters->'sizes') as sizes(value) where sizes.value not like '%:%')) or
       exists (select 1 from public.catalog_effective_size_membership_read sf where sf.product_id = item.id and sf.token in (select sizes.value from jsonb_array_elements_text(filters->'sizes') as sizes(value) where sizes.value like '%:%')))) and
    (omit_group = 'otherSizes' or coalesce(jsonb_array_length(filters->'otherSizes'), 0) = 0 or item.other_sizes && array(select jsonb_array_elements_text(filters->'otherSizes'))) and
    (omit_group = 'materials' or coalesce(jsonb_array_length(filters->'materials'), 0) = 0 or item.materials && array(select jsonb_array_elements_text(filters->'materials'))) and
    (omit_group = 'patterns' or coalesce(jsonb_array_length(filters->'patterns'), 0) = 0 or item.patterns && array(select jsonb_array_elements_text(filters->'patterns'))) and
    (omit_group = 'features' or coalesce(jsonb_array_length(filters->'features'), 0) = 0 or item.features && array(select jsonb_array_elements_text(filters->'features'))) and
    (omit_group = 'styles' or coalesce(jsonb_array_length(filters->'styles'), 0) = 0 or item.styles && array(select jsonb_array_elements_text(filters->'styles'))) and
    (omit_group = 'productTypes' or coalesce(jsonb_array_length(filters->'productTypes'), 0) = 0 or item.product_types && array(select jsonb_array_elements_text(filters->'productTypes'))) and
    (omit_group = 'premium' or coalesce((filters->>'isPremium')::boolean, false) = false or item.is_premium) and
    (omit_group = 'excludeBasics' or coalesce((filters->>'excludeBasics')::boolean, false) = false or not (item.category_names && public.catalog_excluded_basics_categories() or item.categories && public.catalog_excluded_basics_categories())) and
    (omit_group = 'excludeAccessories' or coalesce((filters->>'excludeAccessories')::boolean, false) = false or not (item.category_paths && public.catalog_excluded_accessories_paths())) and
    (omit_group = 'price' or filters->>'priceMin' is null or item.current_price >= (filters->>'priceMin')::integer) and
    (omit_group = 'price' or filters->>'priceMax' is null or item.current_price <= (filters->>'priceMax')::integer) and
    (filters->>'discountMin' is null or item.discount_pct >= (filters->>'discountMin')::numeric) and
    (filters->>'lplProximityPct' is null or (item.source_lpl_30 > 0 and item.current_price * 100.0 / item.source_lpl_30 <= 100 + (filters->>'lplProximityPct')::numeric)) and
    (coalesce((filters->>'belowObserved30d')::boolean, false) = false or case when filters->>'priceComparison' = 'source_lpl' then item.below_source_lpl_30d else item.below_observed_30d end) and
    (coalesce((filters->>'newOnly')::boolean, false) = false or item.first_seen_at >= now() - interval '30 days')
$$;

-- Save an admin override and rebuild its dependent read model/cache in one DB
-- transaction. A refresh error rolls back the override too.
create or replace function public.save_catalog_size_classification_override(
  p_product_id uuid,
  p_size_domain text,
  p_exclude_from_size_filter boolean,
  p_size_value_overrides jsonb,
  p_note text
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  saved public.catalog_size_classification_overrides%rowtype;
begin
  insert into public.catalog_size_classification_overrides (
    product_id, size_domain, exclude_from_size_filter,
    size_value_overrides, note, updated_at
  ) values (
    p_product_id, p_size_domain, p_exclude_from_size_filter,
    p_size_value_overrides, p_note, now()
  ) on conflict (product_id) do update set
    size_domain = excluded.size_domain,
    exclude_from_size_filter = excluded.exclude_from_size_filter,
    size_value_overrides = excluded.size_value_overrides,
    note = excluded.note,
    updated_at = now()
  returning * into saved;

  perform public.invalidate_catalog_facets_cache();
  return jsonb_build_object(
    'sizeDomain', saved.size_domain,
    'excludeFromSizeFilter', saved.exclude_from_size_filter,
    'sizeValueOverrides', saved.size_value_overrides,
    'note', saved.note
  );
end;
$$;

create or replace function public.delete_catalog_size_classification_override(
  p_product_id uuid
) returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  delete from public.catalog_size_classification_overrides
  where product_id = p_product_id;
  if found then
    perform public.invalidate_catalog_facets_cache();
  end if;
end;
$$;

revoke all on function public.save_catalog_size_classification_override(uuid,text,boolean,jsonb,text)
  from public, anon, authenticated;
grant execute on function public.save_catalog_size_classification_override(uuid,text,boolean,jsonb,text)
  to service_role;
revoke all on function public.delete_catalog_size_classification_override(uuid)
  from public, anon, authenticated;
grant execute on function public.delete_catalog_size_classification_override(uuid)
  to service_role;

-- Invalidate payloads whose counts used the earlier category, size or LPL rules.
delete from public.catalog_facets_cache;
notify pgrst, 'reload schema';
commit;
