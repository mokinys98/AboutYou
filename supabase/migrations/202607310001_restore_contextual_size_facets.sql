-- Keep the cheap global size dictionary for the unfiltered catalog, but build
-- and cache a precise size facet for every filtered context. The previous
-- implementation ignored p_filters and therefore showed every catalog size on
-- category pages such as vyrams>drabužiai>džinsai.

create or replace function public.catalog_build_static_size_facets()
returns jsonb
language sql stable security definer
set search_path = public, pg_temp as $$
  with grouped as (
    select
      sf.domain_key,
      max(sf.domain_label) as domain_label,
      sf.value_key,
      max(sf.display_label) as display_label,
      sf.token,
      min(sf.sort_order) as sort_order,
      count(distinct sf.product_id) as product_count
    from public.catalog_size_facets_read_effective sf
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
  from grouped;
$$;

revoke all on function public.catalog_build_static_size_facets()
  from public, anon, authenticated;

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
    join public.catalog_size_facets_read_effective sf
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

create or replace function public.catalog_grouped_size_facets(
  p_filters jsonb default '{}'::jsonb
) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  result jsonb;
begin
  if coalesce(p_filters, '{}'::jsonb) = '{}'::jsonb then
    select payload into result
    from public.catalog_static_size_facets_cache
    where singleton;

    if result is not null then
      return result;
    end if;

    return public.catalog_build_static_size_facets();
  end if;

  return public.catalog_build_contextual_size_facets(p_filters);
end;
$$;

revoke all on function public.catalog_grouped_size_facets(jsonb)
  from public, anon, authenticated;
grant execute on function public.catalog_grouped_size_facets(jsonb)
  to service_role;

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
  result := jsonb_set(result, '{otherSizes}', '[]'::jsonb, true);

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

-- Overrides and catalog refreshes can change the product-to-size membership.
-- Delete every per-filter payload so a category can never reuse stale global or
-- pre-refresh sizes. The next request rebuilds that exact key once and caches it.
create or replace function public.invalidate_catalog_facets_cache()
returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  perform public.refresh_catalog_static_size_facets_cache();
  delete from public.catalog_facets_cache;
end;
$$;

revoke all on function public.invalidate_catalog_facets_cache()
  from public, anon, authenticated;
grant execute on function public.invalidate_catalog_facets_cache()
  to service_role;

create or replace function public.rebuild_catalog_items_read_internal()
returns void
language plpgsql security definer
set search_path = public, pg_temp
set lock_timeout = '3s' as $$
begin
  execute 'refresh materialized view concurrently public.catalog_items_read';
  execute 'refresh materialized view concurrently public.catalog_item_facet_values_read';
  execute 'refresh materialized view concurrently public.catalog_size_facets_read';
  perform public.invalidate_catalog_facets_cache();
end;
$$;

revoke all on function public.rebuild_catalog_items_read_internal()
  from public, anon, authenticated, service_role;

-- Force all browsers to miss the previous static-size payload after deployment.
delete from public.catalog_facets_cache;
select public.refresh_catalog_static_size_facets_cache();

notify pgrst, 'reload schema';
