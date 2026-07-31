-- Group catalog sizes by product domain while keeping the raw sizes columns
-- intact for legacy URLs and data audits.

create or replace function public.catalog_size_domain(
  p_category_paths text[],
  p_category_names text[],
  p_product_name text
) returns text
language sql immutable
set search_path = public, pg_temp as $$
  with source_text as (
    select lower(array_to_string(coalesce(p_category_paths, '{}') || coalesce(p_category_names, '{}'), ' ')
      || ' ' || coalesce(p_product_name, '')) as value
  )
  select case
    when value ~ '(kojin)' then 'socks'
    when value ~ '(apatin)' then 'underwear'
    when value ~ '(bat|ked)' then 'shoes'
    when value ~ '(keln|džins)' then 'trousers'
    when value ~ '(marškin)' then 'shirts'
    when value ~ '(švark|kostium)' then 'suitwear'
    when value ~ '(maudym|bikin|plaukimo)' then 'swimwear'
    when value ~ '(dirž)' then 'belts'
    when value ~ '(kepur|skryb)' then 'headwear'
    when value ~ '(piršt)' then 'gloves'
    when value ~ '(akin)' then 'eyewear'
    when value ~ '(žied)' then 'rings'
    when value ~ '(apyrank)' then 'bracelets'
    when value ~ '(krepš|kuprin)' then 'bags'
    when value ~ '(pinigin|kosmetin)' then 'wallets'
    when value ~ '(aksesuar)' then 'accessories'
    when value ~ '(drabuž)' then 'clothing'
    else 'other'
  end
  from source_text;
$$;

create or replace function public.catalog_size_domain_label(p_domain text)
returns text
language sql immutable
set search_path = public, pg_temp as $$
  select case p_domain
    when 'clothing' then 'Drabužiai'
    when 'shirts' then 'Marškiniai'
    when 'trousers' then 'Kelnės ir džinsai'
    when 'suitwear' then 'Kostiumai ir švarkai'
    when 'underwear' then 'Apatiniai'
    when 'swimwear' then 'Maudymosi drabužiai'
    when 'socks' then 'Kojinės'
    when 'shoes' then 'Batai'
    when 'belts' then 'Diržai'
    when 'headwear' then 'Kepurės ir skrybėlės'
    when 'gloves' then 'Pirštinės'
    when 'eyewear' then 'Akiniai'
    when 'rings' then 'Žiedai'
    when 'bracelets' then 'Apyrankės'
    when 'bags' then 'Krepšiai ir kuprinės'
    when 'wallets' then 'Piniginės ir kosmetinės'
    when 'accessories' then 'Kiti aksesuarai'
    else 'Kita'
  end;
$$;

create or replace function public.catalog_size_value_key(p_value text)
returns text
language sql immutable
set search_path = public, pg_temp as $$
  select lower(regexp_replace(
    regexp_replace(
      regexp_replace(trim(coalesce(p_value, '')), '\s*[×x]\s*', '-', 'gi'),
      '[–—]', '-', 'g'
    ),
    '\s+', '-', 'g'
  ));
$$;

create or replace function public.catalog_size_sort_order(p_value text)
returns numeric
language sql immutable
set search_path = public, pg_temp as $$
  select case lower(trim(coalesce(p_value, '')))
    when 'xxs' then 10 when 'xs' then 20 when 's' then 30 when 'm' then 40
    when 'l' then 50 when 'xl' then 60 when 'xxl' then 70 when 'xxxl' then 80
    when 'vienas dydis' then 900000 when 'onesize' then 900000
    when '1size' then 900000 when 'ns' then 900000
    else coalesce(nullif(substring(trim(coalesce(p_value, '')) from '\d+(\.\d+)?'), '')::numeric, 500000)
  end;
$$;

create materialized view public.catalog_size_facets_read as
with option_values as (
  select i.id as product_id,
    public.catalog_size_domain(i.category_paths, i.category_names, i.name) as domain_key,
    o.label as value,
    o.size_group as second_dimension
  from public.catalog_items_read i
  join public.product_size_options o on o.product_id = i.id and o.selectable
  union all
  select i.id,
    public.catalog_size_domain(i.category_paths, i.category_names, i.name),
    value,
    null
  from public.catalog_items_read i
  cross join lateral unnest(coalesce(i.sizes, '{}') || coalesce(i.other_sizes, '{}')) value
  where not exists (select 1 from public.product_size_options o where o.product_id = i.id)
), normalized as (
  select distinct product_id, domain_key,
    public.catalog_size_domain_label(domain_key) as domain_label,
    public.catalog_size_value_key(value || case when nullif(trim(second_dimension), '') is not null then '-' || trim(second_dimension) else '' end) as value_key,
    case when nullif(trim(second_dimension), '') is not null
      then trim(value) || ' / ' || trim(second_dimension)
      else trim(value) end as display_label,
    public.catalog_size_sort_order(value) as sort_order
  from option_values
  where trim(coalesce(value, '')) <> ''
)
select product_id, domain_key, domain_label, value_key, display_label,
  domain_key || ':' || value_key as token, sort_order
from normalized;

create unique index catalog_size_facets_read_unique_idx
  on public.catalog_size_facets_read (product_id, token);
create index catalog_size_facets_read_token_idx
  on public.catalog_size_facets_read (token, product_id);
create index catalog_size_facets_read_domain_idx
  on public.catalog_size_facets_read (domain_key, sort_order, display_label, product_id);

create or replace view public.catalog_items_read_with_lpl as
select i.*,
  case
    when i.source_lpl_30 is not null and i.source_lpl_30 > 0
      then i.current_price * 100.0 / i.source_lpl_30
    else null
  end as lpl_price_ratio,
  coalesce((select array_agg(sf.token order by sf.domain_key, sf.sort_order, sf.display_label)
    from public.catalog_size_facets_read sf where sf.product_id = i.id), '{}') as size_tokens
from public.catalog_items_read i;

create or replace function public.catalog_grouped_size_facets(p_filters jsonb default '{}'::jsonb)
returns jsonb
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
  ), matching_products as (
    select i.id
    from public.catalog_items_read i
    cross join filter_values f
    where
      (cardinality(f.brands) = 0 or i.brand = any(f.brands)) and
      (cardinality(f.brand_tiers) = 0 or i.brand_tier::text = any(f.brand_tiers)) and
      (cardinality(f.categories) = 0 or i.categories && f.categories) and
      (cardinality(f.colors) = 0 or i.color_family = any(f.colors)) and
      (cardinality(f.color_shades) = 0 or i.color_shade = any(f.color_shades)) and
      (cardinality(f.sources) = 0 or i.source = any(f.sources)) and
      (cardinality(f.product_types) = 0 or i.product_types && f.product_types) and
      (not f.is_premium or i.is_premium) and
      (not f.exclude_basics or not (i.category_names && public.catalog_excluded_basics_categories() or i.categories && public.catalog_excluded_basics_categories())) and
      (not f.exclude_accessories or not (i.category_paths && public.catalog_excluded_accessories_paths())) and
      (f.price_min is null or i.current_price >= f.price_min) and
      (f.price_max is null or i.current_price <= f.price_max) and
      (f.discount_min is null or i.discount_pct >= f.discount_min) and
      (not f.below_minimum or case when f.price_comparison = 'source_lpl' then i.below_source_lpl_30d else i.below_observed_30d end) and
      (not f.new_only or i.first_seen_at >= now() - interval '30 days')
  ), grouped as (
    select sf.domain_key, sf.domain_label, sf.value_key, sf.display_label, sf.token,
      min(sf.sort_order) as sort_order, count(distinct sf.product_id) as product_count
    from public.catalog_size_facets_read sf
    join matching_products mp on mp.id = sf.product_id
    group by sf.domain_key, sf.domain_label, sf.value_key, sf.display_label, sf.token
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

-- This is intentionally an audit function, not a permanent fallback bucket.
-- Once a recurring value in `other` is understood, add a deterministic rule
-- to catalog_size_domain and this report shows whether the bucket shrank.
create or replace function public.catalog_size_classification_audit()
returns table(domain_key text, domain_label text, facet_count bigint, product_count bigint)
language sql stable security definer
set search_path = public, pg_temp as $$
  select domain_key, max(domain_label), count(distinct token), count(distinct product_id)
  from public.catalog_size_facets_read
  group by domain_key
  order by case when domain_key = 'other' then 1 else 0 end, domain_key;
$$;

-- Keep the existing facet payload and replace only the size facet. This makes
-- the migration backwards-compatible for all other filters and clients.
create or replace function public.catalog_facets_cached(p_filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare result jsonb;
begin
  select payload into result from public.catalog_facets_cache where filters = p_filters;
  if found then return result; end if;
  result := public.catalog_facets(p_filters);
  result := jsonb_set(result, '{sizes}', public.catalog_grouped_size_facets(p_filters), true);
  result := jsonb_set(result, '{otherSizes}', '[]'::jsonb, true);
  insert into public.catalog_facets_cache(filters, payload)
  values (p_filters, result)
  on conflict (filters) do update set payload = excluded.payload, created_at = now();
  return result;
end;
$$;

-- Alert evaluation uses the catalog_items_read composite type directly, so
-- keep grouped and legacy size matching in the same server-side predicate.
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
    (omit_group = 'categories' or coalesce(jsonb_array_length(filters->'categories'), 0) = 0 or item.categories && array(select jsonb_array_elements_text(filters->'categories'))) and
    (omit_group = 'sizes' or coalesce(jsonb_array_length(filters->'sizes'), 0) = 0 or
      ((item.sizes && array(select sizes.value from jsonb_array_elements_text(filters->'sizes') as sizes(value) where sizes.value not like '%:%')) or
       exists (select 1 from public.catalog_size_facets_read sf where sf.product_id = item.id and sf.token in (select sizes.value from jsonb_array_elements_text(filters->'sizes') as sizes(value) where sizes.value like '%:%')))) and
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
    (coalesce((filters->>'belowObserved30d')::boolean, false) = false or case when filters->>'priceComparison' = 'source_lpl' then item.below_source_lpl_30d else item.below_observed_30d end) and
    (coalesce((filters->>'newOnly')::boolean, false) = false or item.first_seen_at >= now() - interval '30 days')
$$;

create or replace function public.rebuild_catalog_items_read_internal() returns void
language plpgsql security definer
set search_path = public, pg_temp
set statement_timeout = '90s'
set lock_timeout = '3s' as $$
begin
  execute 'refresh materialized view concurrently public.catalog_items_read';
  execute 'refresh materialized view public.catalog_item_facet_values_read';
  execute 'refresh materialized view public.catalog_size_facets_read';
  delete from public.catalog_facets_cache;
  perform public.catalog_facets_cached('{}'::jsonb);
end;
$$;

revoke all on table public.catalog_size_facets_read from public, anon, authenticated;
grant select on table public.catalog_size_facets_read to service_role;
revoke all on function public.catalog_grouped_size_facets(jsonb) from public, anon, authenticated;
grant execute on function public.catalog_grouped_size_facets(jsonb) to service_role;
revoke all on function public.catalog_size_classification_audit() from public, anon, authenticated;
grant execute on function public.catalog_size_classification_audit() to service_role;
revoke all on function public.catalog_facets_cached(jsonb) from public, anon, authenticated;
grant execute on function public.catalog_facets_cached(jsonb) to service_role;
revoke all on table public.catalog_items_read_with_lpl from public, anon, authenticated;
grant select on table public.catalog_items_read_with_lpl to service_role;

delete from public.catalog_facets_cache;
select public.catalog_facets_cached('{}'::jsonb);

notify pgrst, 'reload schema';
