-- catalog_facets() historically matches its categories filter against the
-- human-readable catalog_items_read.categories array, while the API sends a
-- full category path such as vyrams>drabužiai>džinsai. Keep the exact path for
-- cache identity and contextual sizes, but expand it with the canonical
-- category name before invoking the legacy non-size facet builder.

create or replace function public.catalog_facets_cached(
  p_filters jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  result jsonb;
  cache_filters jsonb := coalesce(p_filters, '{}'::jsonb);
  facet_filters jsonb;
  expanded_categories jsonb;
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

  facet_filters := cache_filters;

  if coalesce(jsonb_array_length(cache_filters->'categories'), 0) > 0 then
    select coalesce(jsonb_agg(expanded.value order by expanded.value), '[]'::jsonb)
    into expanded_categories
    from (
      select distinct requested.value
      from jsonb_array_elements_text(cache_filters->'categories') requested(value)

      union

      select distinct category.name
      from jsonb_array_elements_text(cache_filters->'categories') requested(value)
      join public.categories category
        on category.path = requested.value
      where category.name is not null
    ) expanded;

    facet_filters := jsonb_set(
      facet_filters,
      '{categories}',
      expanded_categories,
      true
    );
  end if;

  result := public.catalog_facets(facet_filters);
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

delete from public.catalog_facets_cache;

notify pgrst, 'reload schema';
