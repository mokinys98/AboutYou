-- Size choices are catalog facts, not contextual counters. Keep the list
-- stable while other filters change and avoid rebuilding every cached facet
-- payload after a manual size-classification override.

create or replace function public.catalog_grouped_size_facets(
  p_filters jsonb default '{}'::jsonb
) returns jsonb
language sql stable security definer
set search_path = public, pg_temp as $$
  with grouped as (
    select
      sf.domain_key,
      max(sf.domain_label) as domain_label,
      sf.value_key,
      max(sf.display_label) as display_label,
      sf.token,
      min(sf.sort_order) as sort_order
    from public.catalog_size_facets_read_effective sf
    group by sf.domain_key, sf.value_key, sf.token
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'value', grouped.token,
    'label', grouped.display_label,
    'domainKey', grouped.domain_key,
    'domainLabel', grouped.domain_label,
    'valueKey', grouped.value_key,
    'sortOrder', grouped.sort_order
  ) order by grouped.domain_key, grouped.sort_order, grouped.display_label), '[]'::jsonb)
  from grouped;
$$;

revoke all on function public.catalog_grouped_size_facets(jsonb)
  from public, anon, authenticated;
grant execute on function public.catalog_grouped_size_facets(jsonb)
  to service_role;

-- API defaults serialize an unfiltered request as a JSON object containing
-- empty arrays and false flags. Canonicalize it to `{}` so the API and refresh
-- worker share one root-cache entry.
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
  result := jsonb_set(result, '{sizes}', public.catalog_grouped_size_facets(), true);
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

-- A manual size override changes only the static size list. Preserve the
-- expensive brand/category/material cache and replace its size fields in place.
create or replace function public.invalidate_catalog_facets_cache()
returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  size_facets jsonb;
begin
  size_facets := public.catalog_grouped_size_facets();

  update public.catalog_facets_cache
  set payload = jsonb_set(
        jsonb_set(payload, '{sizes}', size_facets, true),
        '{otherSizes}',
        '[]'::jsonb,
        true
      ),
      created_at = now();
end;
$$;

revoke all on function public.invalidate_catalog_facets_cache()
  from public, anon, authenticated;
grant execute on function public.invalidate_catalog_facets_cache()
  to service_role;

-- Refresh every read model concurrently. Do not calculate the full facet
-- payload while refresh locks are still held; the cache is rebuilt lazily
-- after this transaction commits.
create or replace function public.rebuild_catalog_items_read_internal()
returns void
language plpgsql security definer
set search_path = public, pg_temp
set lock_timeout = '3s' as $$
begin
  execute 'refresh materialized view concurrently public.catalog_items_read';
  execute 'refresh materialized view concurrently public.catalog_item_facet_values_read';
  execute 'refresh materialized view concurrently public.catalog_size_facets_read';
  delete from public.catalog_facets_cache;
end;
$$;

revoke all on function public.rebuild_catalog_items_read_internal()
  from public, anon, authenticated, service_role;

-- Function-local statement_timeout settings do not reliably arm a timeout for
-- the already-running outer statement. Set it in pg_cron's session before the
-- worker call instead, with enough room for the observed ~134 second refresh.
alter function public.catalog_facets_cached(jsonb) reset statement_timeout;
alter function public.catalog_grouped_size_facets(jsonb) reset statement_timeout;
alter function public.rebuild_catalog_items_read_internal() reset statement_timeout;
alter function public.process_catalog_items_read_refresh() reset statement_timeout;
alter function public.refresh_catalog_items_read() reset statement_timeout;

update cron.job
set command = $cron$
  set statement_timeout = '5min';
  set lock_timeout = '3s';
  select public.process_catalog_items_read_refresh();
$cron$,
    active = true
where jobname = 'catalog-read-model-refresh';

-- Existing cached payloads remain useful; replace only their size fields.
select public.invalidate_catalog_facets_cache();

notify pgrst, 'reload schema';
