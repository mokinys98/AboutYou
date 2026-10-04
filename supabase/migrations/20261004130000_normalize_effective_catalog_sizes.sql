-- Normalize effective tokens without changing the source materialized view's
-- existing unique index. Effective membership deduplicates product/token rows.
begin;

create or replace function public.catalog_effective_size_value_key(p_value text)
returns text
language sql immutable
set search_path = public, pg_temp as $$
  select case
    when regexp_replace(lower(trim(coalesce(p_value, ''))), '[[:space:]_-]+', '', 'g')
      in ('vienasdydis', 'onesize', '1size', 'ns') then 'one-size'
    else regexp_replace(public.catalog_size_value_key(p_value), '([0-9]),([0-9])', '\1.\2', 'g')
  end;
$$;

create or replace function public.catalog_effective_size_sort_order(p_value_key text)
returns numeric
language sql immutable
set search_path = public, pg_temp as $$
  select case
    when p_value_key = 'one-size' then 900000
    when p_value_key ~ '^w?[0-9]+-l?[0-9]+$' then
      substring(p_value_key from '^w?([0-9]+)')::numeric * 1000 +
      substring(p_value_key from '-l?([0-9]+)$')::numeric
    else public.catalog_size_sort_order(p_value_key)
  end;
$$;

revoke all on function public.catalog_effective_size_value_key(text)
  from public, anon, authenticated;
grant execute on function public.catalog_effective_size_value_key(text)
  to service_role;
revoke all on function public.catalog_effective_size_sort_order(text)
  from public, anon, authenticated;

create or replace view public.catalog_size_facets_read_effective as
with source_values as (
  select
    sf.product_id,
    coalesce(o.size_domain, sf.domain_key) as domain_key,
    sf.value_key as source_value_key,
    sf.display_label as source_display_label,
    sf.sort_order,
    o.size_value_overrides -> sf.display_label as value_override
  from public.catalog_size_facets_read sf
  left join public.catalog_size_classification_overrides o
    on o.product_id = sf.product_id
  where coalesce(o.exclude_from_size_filter, false) = false
), normalized as (
  select
    product_id,
    domain_key,
    public.catalog_size_domain_label(domain_key) as domain_label,
    case
      when value_override is null then public.catalog_effective_size_value_key(source_value_key)
      else public.catalog_effective_size_value_key(
        coalesce(nullif(trim(value_override->>'label'), ''), source_display_label)
        || case
          when nullif(trim(value_override->>'sizeGroup'), '') is not null
            then '-' || trim(value_override->>'sizeGroup')
          else ''
        end
      )
    end as value_key,
    case
      when value_override is null then source_display_label
      else coalesce(nullif(trim(value_override->>'label'), ''), source_display_label)
        || case
          when nullif(trim(value_override->>'sizeGroup'), '') is not null
            then ' / ' || trim(value_override->>'sizeGroup')
          else ''
        end
    end as display_label,
    sort_order
  from source_values
)
select
  product_id,
  domain_key,
  domain_label,
  value_key,
  display_label,
  domain_key || ':' || value_key as token,
  public.catalog_effective_size_sort_order(value_key) as sort_order
from normalized;

revoke all on table public.catalog_size_facets_read_effective
  from public, anon, authenticated;
grant select on table public.catalog_size_facets_read_effective
  to service_role;

-- Saved alerts and older URLs may contain pre-normalization size tokens.
create or replace function public.catalog_canonical_size_token(p_token text)
returns text
language sql immutable
set search_path = public, pg_temp as $$
  select case
    when position(':' in p_token) = 0 then p_token
    else split_part(p_token, ':', 1) || ':' ||
      public.catalog_effective_size_value_key(substr(p_token, position(':' in p_token) + 1))
  end;
$$;

revoke all on function public.catalog_canonical_size_token(text)
  from public, anon, authenticated;
grant execute on function public.catalog_canonical_size_token(text)
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
       exists (select 1 from public.catalog_effective_size_membership_read sf where sf.product_id = item.id and sf.token in (select public.catalog_canonical_size_token(sizes.value) from jsonb_array_elements_text(filters->'sizes') as sizes(value) where sizes.value like '%:%')))) and
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

-- Refresh the prepared membership, global dictionary and per-filter cache
-- under the updated normalization rules.
select public.invalidate_catalog_facets_cache();
notify pgrst, 'reload schema';
commit;
