-- Manual classification overrides are deliberately separate from source sync
-- data. A metadata/catalog sync must never delete or replace these rows.

create table public.catalog_size_classification_overrides (
  product_id uuid primary key references public.products(id) on delete cascade,
  size_domain text not null check (size_domain in (
    'clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear',
    'socks', 'shoes', 'belts', 'headwear', 'gloves', 'eyewear', 'rings',
    'bracelets', 'bags', 'wallets', 'accessories', 'other'
  )),
  exclude_from_size_filter boolean not null default false,
  size_value_overrides jsonb not null default '{}'::jsonb check (jsonb_typeof(size_value_overrides) = 'object'),
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.catalog_size_classification_overrides enable row level security;
revoke all on table public.catalog_size_classification_overrides from public, anon, authenticated;
grant select, insert, update, delete on table public.catalog_size_classification_overrides to service_role;

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

create or replace view public.catalog_size_facets_read_effective as
select sf.product_id,
  coalesce(o.size_domain, public.catalog_size_domain(i.category_paths, i.category_names, i.name)) as domain_key,
  public.catalog_size_domain_label(coalesce(o.size_domain, public.catalog_size_domain(i.category_paths, i.category_names, i.name))) as domain_label,
  sf.value_key,
  sf.display_label,
  coalesce(o.size_domain, public.catalog_size_domain(i.category_paths, i.category_names, i.name)) || ':' || sf.value_key as token,
  sf.sort_order
from public.catalog_size_facets_read sf
join public.catalog_items_read i on i.id = sf.product_id
left join public.catalog_size_classification_overrides o on o.product_id = sf.product_id
where coalesce(o.exclude_from_size_filter, false) = false;

revoke all on table public.catalog_size_facets_read_effective from public, anon, authenticated;
grant select on table public.catalog_size_facets_read_effective to service_role;

create or replace view public.catalog_items_read_with_lpl as
select i.*,
  case
    when i.source_lpl_30 is not null and i.source_lpl_30 > 0
      then i.current_price * 100.0 / i.source_lpl_30
    else null
  end as lpl_price_ratio,
  coalesce((select array_agg(sf.token order by sf.domain_key, sf.sort_order, sf.display_label)
    from public.catalog_size_facets_read_effective sf where sf.product_id = i.id), '{}') as size_tokens
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
    from public.catalog_items_read i cross join filter_values f
    where (cardinality(f.brands) = 0 or i.brand = any(f.brands))
      and (cardinality(f.brand_tiers) = 0 or i.brand_tier::text = any(f.brand_tiers))
      and (cardinality(f.categories) = 0 or i.categories && f.categories)
      and (cardinality(f.colors) = 0 or i.color_family = any(f.colors))
      and (cardinality(f.color_shades) = 0 or i.color_shade = any(f.color_shades))
      and (cardinality(f.sources) = 0 or i.source = any(f.sources))
      and (cardinality(f.product_types) = 0 or i.product_types && f.product_types)
      and (not f.is_premium or i.is_premium)
      and (not f.exclude_basics or not (i.category_names && public.catalog_excluded_basics_categories() or i.categories && public.catalog_excluded_basics_categories()))
      and (not f.exclude_accessories or not (i.category_paths && public.catalog_excluded_accessories_paths()))
      and (f.price_min is null or i.current_price >= f.price_min)
      and (f.price_max is null or i.current_price <= f.price_max)
      and (f.discount_min is null or i.discount_pct >= f.discount_min)
      and (not f.below_minimum or case when f.price_comparison = 'source_lpl' then i.below_source_lpl_30d else i.below_observed_30d end)
      and (not f.new_only or i.first_seen_at >= now() - interval '30 days')
  ), grouped as (
    select sf.domain_key, sf.domain_label, sf.value_key, sf.display_label, sf.token,
      min(sf.sort_order) as sort_order, count(distinct sf.product_id) as product_count
    from public.catalog_size_facets_read_effective sf
    join matching_products mp on mp.id = sf.product_id
    group by sf.domain_key, sf.domain_label, sf.value_key, sf.display_label, sf.token
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'value', grouped.token, 'label', grouped.display_label,
    'domainKey', grouped.domain_key, 'domainLabel', grouped.domain_label,
    'valueKey', grouped.value_key, 'sortOrder', grouped.sort_order,
    'count', grouped.product_count
  ) order by grouped.domain_key, grouped.sort_order, grouped.display_label), '[]'::jsonb)
  from grouped;
$$;

create or replace function public.catalog_size_classification_audit()
returns table(domain_key text, domain_label text, facet_count bigint, product_count bigint)
language sql stable security definer
set search_path = public, pg_temp as $$
  select domain_key, max(domain_label), count(distinct token), count(distinct product_id)
  from public.catalog_size_facets_read_effective
  group by domain_key
  order by case when domain_key = 'other' then 1 else 0 end, domain_key;
$$;

revoke all on function public.catalog_grouped_size_facets(jsonb) from public, anon, authenticated;
grant execute on function public.catalog_grouped_size_facets(jsonb) to service_role;
revoke all on function public.catalog_size_classification_audit() from public, anon, authenticated;
grant execute on function public.catalog_size_classification_audit() to service_role;

delete from public.catalog_facets_cache;
select public.catalog_facets_cached('{}'::jsonb);
notify pgrst, 'reload schema';
