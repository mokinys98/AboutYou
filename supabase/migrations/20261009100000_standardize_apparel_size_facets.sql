-- Normalize clear apparel alpha-size aliases and descriptive variants while
-- retaining numeric clothing sizes and distinct trouser waist/inseam pairs.
-- EU numeric-to-alpha conversion is intentionally omitted because the mapping
-- varies by garment category, gender and cut; those values need richer context.
begin;

create or replace function public.catalog_effective_size_value_key(
  p_domain text,
  p_value text
) returns text
language sql immutable
set search_path = public, pg_temp as $$
  with source as (
    select trim(coalesce(p_value, '')) as raw,
      translate(lower(trim(coalesce(p_value, ''))), '–—−‐‑', '-----') as lowered
  ), parsed as (
    select raw, lowered,
      regexp_match(case when p_domain = 'trousers' then lowered end,
        '^(?:w[[:space:]]*)?([0-9]{2,3})[[:space:]]*[x×][[:space:]]*(?:l[[:space:]]*)?([0-9]{2,3})(?:[[:space:]]*/[[:space:]]*(?:l[[:space:]]*)?\2)?$') as waist_inseam,
      regexp_match(case when p_domain = 'trousers' then lowered end,
        '^(?:w[[:space:]]*)?([0-9]{2,3})[[:space:]]*[x×][[:space:]]*(?:[[:alpha:]]prastas[[:space:]]+ilgis|normalus[[:space:]]+ilgis|trumpas|ilgas|slim|tall|regular[[:space:]]+length|short|long)(?:[[:space:]]*/.*)?$') as waist_with_length_label,
      regexp_match(case when p_domain in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear') then lowered end,
        '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl|[2-8]xl)[[:space:]]*-[[:space:]]*(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl|[2-8]xl)(?:(?:[-/]|[[:space:]]).*(ilgis|ilgas|trumpas|dy[^[:space:]-]{1,2}io|slim|tall|fit|length|short|long).*)?$') as alpha_range,
      regexp_match(case when p_domain in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear') then lowered end,
        '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl|[2-8]xl)(?:[[:space:]/].*(ilgis|ilgas|trumpas|dy[^[:space:]]{1,2}io|slim|tall|fit|length|short|long).*)$') as alpha_with_description,
      regexp_match(case when p_domain in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear') then lowered end,
        '^(-{1,8}[ls])$') as legacy_alpha_key,
      regexp_match(case when p_domain in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear') then lowered end,
        '^((?:xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl|[2-8]xl|-{1,8}[ls]|[2-8]-[ls]))-((?:xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl|[2-8]xl|-{1,8}[ls]|[2-8]-[ls]))(?:(?:[-/]|[[:space:]]).*(?:ilgis|ilgas|trumpas|dy[^[:space:]-]{1,2}io|slim|tall|fit|length|short|long).*)?$') as legacy_alpha_range,
      regexp_match(case when p_domain in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear') then lowered end,
        '^(-{1,8}[ls]|[2-8]-[ls])(?:[-/]|[[:space:]]).*(?:ilgis|ilgas|trumpas|dy[^[:space:]-]{1,2}io|slim|tall|fit|length|short|long)$') as legacy_alpha_description,
      regexp_match(case when p_domain in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear') then lowered end,
        '^([2-8])-([ls])$') as legacy_numeric_alpha_key,
      regexp_match(case when p_domain in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear') then lowered end,
        '^([2-8])-([ls])-([2-8])-([ls])$') as legacy_numeric_alpha_range
    from source
  ), alpha as (
    select *, case
      when alpha_range is not null then
        (case (alpha_range)[1]
          when '2xl' then 'xxl' when '3xl' then 'xxxl'
          when '4xl' then 'xxxxl' when '5xl' then 'xxxxxl'
          when '6xl' then 'xxxxxxl' when '7xl' then 'xxxxxxxl'
          when '8xl' then 'xxxxxxxxl' else (alpha_range)[1] end)
        || '-' ||
        (case (alpha_range)[2]
          when '2xl' then 'xxl' when '3xl' then 'xxxl'
          when '4xl' then 'xxxxl' when '5xl' then 'xxxxxl'
          when '6xl' then 'xxxxxxl' when '7xl' then 'xxxxxxxl'
          when '8xl' then 'xxxxxxxxl' else (alpha_range)[2] end)
      else null
    end as alpha_range_key, case
      when p_domain in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear') and lowered ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'
        then upper(lowered)
      when p_domain in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear') and lowered ~ '^[2-8]xl$'
        then repeat('X', substring(lowered from '^([2-8])')::integer) || 'L'
      when alpha_with_description is not null then
        case lower((alpha_with_description)[1])
          when '2xl' then 'XXL' when '3xl' then 'XXXL'
          when '4xl' then 'XXXXL' when '5xl' then 'XXXXXL'
          when '6xl' then 'XXXXXXL' when '7xl' then 'XXXXXXXL'
          when '8xl' then 'XXXXXXXXL'
          else upper((alpha_with_description)[1])
        end
      else null
    end as alpha_key
    from parsed
  )
  select case
    when p_domain not in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear')
      then public.catalog_effective_size_value_key(p_value)
    when alpha_range_key is not null then alpha_range_key
    when legacy_alpha_key is not null
      then repeat('x', length((legacy_alpha_key)[1]) - 1) || right((legacy_alpha_key)[1], 1)
    when legacy_alpha_description is not null
      then case
        when (legacy_alpha_description)[1] ~ '^(-+)[ls]$'
          then repeat('x', length((legacy_alpha_description)[1]) - 1) || right((legacy_alpha_description)[1], 1)
        else repeat('x', substring((legacy_alpha_description)[1] from '^([2-8])')::integer) || right((legacy_alpha_description)[1], 1)
      end
    when legacy_alpha_range is not null
      then
        (case
          when (legacy_alpha_range)[1] ~ '^(-+)[ls]$'
            then repeat('x', length((legacy_alpha_range)[1]) - 1) || right((legacy_alpha_range)[1], 1)
          when (legacy_alpha_range)[1] ~ '^[2-8]-[ls]$'
            then repeat('x', substring((legacy_alpha_range)[1] from '^([2-8])')::integer) || right((legacy_alpha_range)[1], 1)
          when (legacy_alpha_range)[1] ~ '^[2-8]xl$'
            then repeat('x', substring((legacy_alpha_range)[1] from '^([2-8])')::integer) || 'l'
          else (legacy_alpha_range)[1]
        end) || '-' ||
        (case
          when (legacy_alpha_range)[2] ~ '^(-+)[ls]$'
            then repeat('x', length((legacy_alpha_range)[2]) - 1) || right((legacy_alpha_range)[2], 1)
          when (legacy_alpha_range)[2] ~ '^[2-8]-[ls]$'
            then repeat('x', substring((legacy_alpha_range)[2] from '^([2-8])')::integer) || right((legacy_alpha_range)[2], 1)
          when (legacy_alpha_range)[2] ~ '^[2-8]xl$'
            then repeat('x', substring((legacy_alpha_range)[2] from '^([2-8])')::integer) || 'l'
          else (legacy_alpha_range)[2]
        end)
    when legacy_numeric_alpha_key is not null
      then repeat('x', ((legacy_numeric_alpha_key)[1])::integer) || (legacy_numeric_alpha_key)[2]
    when legacy_numeric_alpha_range is not null
      then repeat('x', ((legacy_numeric_alpha_range)[1])::integer) || (legacy_numeric_alpha_range)[2] || '-' ||
        repeat('x', ((legacy_numeric_alpha_range)[3])::integer) || (legacy_numeric_alpha_range)[4]
    when alpha_key is not null then lower(alpha_key)
    when p_domain = 'trousers' and waist_inseam is not null
      then 'w' || (waist_inseam)[1] || '-l' || (waist_inseam)[2]
    when p_domain = 'trousers' and waist_with_length_label is not null
      then (waist_with_length_label)[1]
    when lowered ~ '^([[:alpha:]]prastas[[:space:]]+ilgis|normalus[[:space:]]+ilgis|trumpas|ilgas|slim|tall|regular[[:space:]]+length|short|long|normalaus[[:space:]]+dy[^[:space:]]{1,2}io|regular[[:space:]]+fit)$'
      then null
    when p_domain = 'trousers' and lowered ~ '^w[[:space:]]*[0-9]{2,3}[[:space:]]*l[[:space:]]*[0-9]{2,3}$'
      then 'w' || regexp_replace(lowered, '^w[[:space:]]*([0-9]{2,3})[[:space:]]*l[[:space:]]*([0-9]{2,3})$', '\1-l\2')
    when p_domain = 'trousers' and lowered ~ '^w[0-9]{2,3}-l[0-9]{2,3}$'
      then lowered
    when p_domain = 'trousers' and lowered ~ '^([0-9]{2,3})-([0-9]{2,3})-\2$'
      then 'w' || regexp_replace(lowered, '^([0-9]{2,3})-([0-9]{2,3})-\2$', '\1-l\2')
    else public.catalog_effective_size_value_key(p_value)
  end
  from alpha;
$$;

-- Keep the existing one-argument normalizer available for non-domain callers.
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
    when p_value_key = 'xxxs' then 5
    when p_value_key = 'xxs' then 10
    when p_value_key = 'xs' then 20
    when p_value_key = 's' then 30
    when p_value_key = 'm' then 40
    when p_value_key = 'l' then 50
    when p_value_key = 'xl' then 60
    when p_value_key = 'xxl' then 70
    when p_value_key = 'xxxl' then 80
    when p_value_key = 'xxxxl' then 90
    when p_value_key = 'xxxxxl' then 100
    when p_value_key = 'xxxxxxl' then 110
    when p_value_key = 'xxxxxxxl' then 120
    when p_value_key = 'xxxxxxxxl' then 130
    else public.catalog_size_sort_order(p_value_key)
  end;
$$;

create or replace function public.catalog_canonical_size_token(p_token text)
returns text
language sql immutable
set search_path = public, pg_temp as $$
  select case
    when position(':' in coalesce(p_token, '')) = 0 then p_token
    else split_part(p_token, ':', 1) || ':' ||
      coalesce(public.catalog_effective_size_value_key(
        split_part(p_token, ':', 1),
        substr(p_token, position(':' in p_token) + 1)
      ), substr(p_token, position(':' in p_token) + 1))
  end;
$$;

create or replace function public.catalog_canonical_size_tokens(p_token text)
returns text[]
language plpgsql immutable
set search_path = public, pg_temp as $$
begin
  if position(':' in coalesce(p_token, '')) = 0 then
    return array[p_token];
  end if;

  return (
    with parts as (
      select split_part(p_token, ':', 1) as domain_key,
        substr(p_token, position(':' in p_token) + 1) as raw_value,
        public.catalog_effective_size_value_key(
          split_part(p_token, ':', 1),
          substr(p_token, position(':' in p_token) + 1)
        ) as value_key
    )
    select case
      when domain_key = 'trousers' and raw_value ~ '^[0-9]{2,3}-[0-9]{2,3}$'
        then array[
          domain_key || ':' || raw_value,
          domain_key || ':w' || split_part(raw_value, '-', 1) || '-l' || split_part(raw_value, '-', 2)
        ]
      when domain_key in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear')
        and value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)-(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'
        then array[
          domain_key || ':' || split_part(value_key, '-', 1),
          domain_key || ':' || split_part(value_key, '-', 2)
        ]
      else array[public.catalog_canonical_size_token(p_token)]
    end
    from parts
  );
end;
$$;

revoke all on function public.catalog_effective_size_value_key(text, text)
  from public, anon, authenticated;
grant execute on function public.catalog_effective_size_value_key(text, text)
  to service_role;
revoke all on function public.catalog_effective_size_value_key(text)
  from public, anon, authenticated;
grant execute on function public.catalog_effective_size_value_key(text)
  to service_role;
revoke all on function public.catalog_canonical_size_token(text)
  from public, anon, authenticated;
grant execute on function public.catalog_canonical_size_token(text)
  to service_role;
revoke all on function public.catalog_canonical_size_tokens(text)
  from public, anon, authenticated;
grant execute on function public.catalog_canonical_size_tokens(text)
  to service_role;

create or replace view public.catalog_size_facets_read_effective as
with source_values as (
  select
    sf.product_id,
    coalesce(o.size_domain, sf.domain_key) as domain_key,
    sf.value_key as source_value_key,
    sf.display_label as source_display_label,
    sf.sort_order,
    o.size_value_overrides -> sf.display_label as value_override,
    case
      when o.size_value_overrides -> sf.display_label is null then sf.display_label
      else coalesce(nullif(trim((o.size_value_overrides -> sf.display_label)->>'label'), ''), sf.display_label)
        || case
          when nullif(trim((o.size_value_overrides -> sf.display_label)->>'sizeGroup'), '') is not null
            then ' / ' || trim((o.size_value_overrides -> sf.display_label)->>'sizeGroup')
          else ''
        end
    end as normalization_input
  from public.catalog_size_facets_read sf
  left join public.catalog_size_classification_overrides o
    on o.product_id = sf.product_id
  where coalesce(o.exclude_from_size_filter, false) = false
), normalized_keys as (
  select
    product_id,
    domain_key,
    public.catalog_size_domain_label(domain_key) as domain_label,
    public.catalog_effective_size_value_key(domain_key, normalization_input) as value_key,
    public.catalog_effective_size_value_key(source_value_key) as original_key,
    source_display_label,
    value_override,
    sort_order
  from source_values
), normalized as (
  select
    product_id,
    domain_key,
    domain_label,
    value_key,
    case
      when value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'
        then upper(value_key)
      when value_key ~ '^w[0-9]{2,3}-l[0-9]{2,3}$'
        then 'W' || substring(value_key from '^w([0-9]{2,3})') || ' × L'
          || substring(value_key from '-l([0-9]{2,3})$')
      when value_key is null then null
      when value_key <> original_key then value_key
      else coalesce(nullif(trim(value_override->>'label'), ''), source_display_label)
    end as display_label,
    sort_order
  from normalized_keys
), expanded as (
  select
    normalized.*,
    component.value_key as facet_value_key
  from normalized
  cross join lateral unnest(
    case
      when normalized.value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)-(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'
        then string_to_array(normalized.value_key, '-')
      else array[normalized.value_key]
    end
  ) as component(value_key)
)
select
  product_id,
  domain_key,
  domain_label,
  facet_value_key as value_key,
  case when facet_value_key <> value_key then upper(facet_value_key) else display_label end as display_label,
  domain_key || ':' || facet_value_key as token,
  public.catalog_effective_size_sort_order(facet_value_key) as sort_order
from expanded
where facet_value_key is not null;

revoke all on table public.catalog_size_facets_read_effective
  from public, anon, authenticated;
grant select on table public.catalog_size_facets_read_effective
  to service_role;

-- Keep saved alpha-range filters and old trouser W-L tokens compatible with
-- the expanded canonical membership while retaining bare numeric matches.
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
       exists (
         select 1
         from public.catalog_effective_size_membership_read sf
         cross join lateral jsonb_array_elements_text(filters->'sizes') as sizes(value)
         where sf.product_id = item.id
           and sizes.value like '%:%'
           and sf.token = any(public.catalog_canonical_size_tokens(sizes.value))
       ))) and
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

-- Expand legacy alpha-range tokens before non-size facets are evaluated too;
-- deduplicate while retaining request/component order for stable cache keys.
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
      (select coalesce(jsonb_agg(value order by first_ordinal), '[]'::jsonb)
       from (
         select value, min(sort_ordinal) as first_ordinal
         from (
           select expanded.value,
             requested.ordinality * 1000 + expanded.ordinality as sort_ordinal
           from jsonb_array_elements_text(cache_filters->'sizes')
             with ordinality as requested(value, ordinality)
           cross join lateral unnest(public.catalog_canonical_size_tokens(requested.value))
             with ordinality as expanded(value, ordinality)
         ) as expanded_values
         group by value
       ) as distinct_values),
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

-- Refresh the size membership and facet caches in a separate SQL Editor request
-- after this DDL transaction commits. This keeps a long refresh from rolling
-- back the function/view definitions if the editor request is interrupted.
notify pgrst, 'reload schema';
commit;
