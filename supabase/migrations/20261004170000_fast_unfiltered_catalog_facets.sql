-- Fast path for the unfiltered facet request. With no filters, every item
-- passes catalog_facets() checks, so the prepared distinct facet read model can
-- be aggregated directly. Keep the payload shape and ordering identical.
begin;

create or replace function public.catalog_root_facets()
returns jsonb
language sql stable security definer
set search_path = public, pg_temp as $$
  with facet_counts as materialized (
    select facet_group, value, count(*) as product_count
    from public.catalog_item_facet_values_read
    group by facet_group, value
  ), product_summary as (
    select count(*) filter (where is_premium) as premium_count,
      coalesce(min(current_price), 0) as price_min,
      coalesce(max(current_price), 0) as price_max
    from public.catalog_items_read
  )
  select jsonb_build_object(
    'brands', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'brands'), '[]'::jsonb),
    'brandTiers', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'brandTiers'), '[]'::jsonb),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', category.id, 'parentId', category.parent_id, 'name', category.name, 'level', category.level, 'path', category.path, 'count', counts.product_count) order by category.level, category.name), '[]'::jsonb) from facet_counts counts join public.categories category on category.path = counts.value where counts.facet_group = 'categories' and category.level between 2 and 4 and category.path <> 'vyrams>premium' and counts.product_count > 0),
    'colors', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'colors'), '[]'::jsonb),
    'colorShades', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'colorShades'), '[]'::jsonb),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'sources'), '[]'::jsonb),
    'sizes', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'sizes'), '[]'::jsonb),
    'otherSizes', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'otherSizes'), '[]'::jsonb),
    'materials', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'materials'), '[]'::jsonb),
    'patterns', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'patterns'), '[]'::jsonb),
    'features', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'features'), '[]'::jsonb),
    'styles', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'styles'), '[]'::jsonb),
    'productTypes', coalesce((select jsonb_agg(jsonb_build_object('value', value, 'count', product_count) order by value) from facet_counts where facet_group = 'productTypes'), '[]'::jsonb),
    'premium', jsonb_build_object('count', product_summary.premium_count),
    'price', jsonb_build_object('min', product_summary.price_min, 'max', product_summary.price_max)
  )
  from product_summary;
$$;

revoke all on function public.catalog_root_facets()
  from public, anon, authenticated;

create or replace function public.catalog_facets_cached(
  p_filters jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  result jsonb;
  cache_filters jsonb := coalesce(p_filters, '{}'::jsonb);
begin
  if jsonb_typeof(cache_filters->'sizes') = 'array' then
    cache_filters := jsonb_set(cache_filters, '{sizes}',
      (select coalesce(jsonb_agg(public.catalog_canonical_size_token(value) order by ordinal), '[]'::jsonb)
       from jsonb_array_elements_text(cache_filters->'sizes') with ordinality as requested(value, ordinal)),
      true);
  end if;

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

  result := case
    when cache_filters = '{}'::jsonb then public.catalog_root_facets()
    else public.catalog_facets(cache_filters)
  end;
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

notify pgrst, 'reload schema';
commit;
