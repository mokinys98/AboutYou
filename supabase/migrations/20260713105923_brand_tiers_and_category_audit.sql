create table public.brand_tiers (
  brand_key text primary key,
  display_name text not null,
  tier text not null check (tier in ('S', 'A', 'B', 'C', 'D')),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  check (brand_key = lower(regexp_replace(trim(display_name), '\s+', ' ', 'g')))
);

alter table public.brand_tiers enable row level security;
revoke all on table public.brand_tiers from public, anon, authenticated;
grant select, insert, update, delete on table public.brand_tiers to service_role;

insert into public.brand_tiers(brand_key, display_name, tier)
select lower(regexp_replace(trim(brand), '\s+', ' ', 'g')), min(brand), 'C'
from public.products
where trim(brand) <> ''
group by lower(regexp_replace(trim(brand), '\s+', ' ', 'g'))
on conflict (brand_key) do nothing;

insert into public.brand_tiers(brand_key, display_name, tier)
select lower(regexp_replace(trim(display_name), '\s+', ' ', 'g')), display_name, tier
from (values
  ('Giuseppe Zanotti', 'S'), ('VALENTINO', 'S'),
  ('BOSS', 'A'), ('BOSS Black', 'A'), ('Polo Ralph Lauren', 'A'), ('Ralph Lauren', 'A'),
  ('Boggi Milano', 'A'), ('Emporio Armani', 'A'), ('DRYKORN', 'A'), ('AllSaints', 'A'),
  ('Hackett London', 'A'), ('NN07', 'A'), ('Samsøe Samsøe', 'A'), ('Schott NYC', 'A'),
  ('NORSE PROJECTS', 'A'), ('UGG', 'A'), ('SAVE THE DUCK', 'A'), ('BOGNER', 'A'),
  ('COACH', 'A'), ('ETON', 'A'), ('Colmar', 'A'), ('Marc Jacobs', 'A'), ('Tory Burch', 'A'),
  ('Les Deux', 'A'), ('DSQUARED2', 'A'), ('AMBUSH', 'A'), ('FRAME', 'A'),
  ('Tiger of Sweden', 'A'), ('Dondup', 'A'), ('The Kooples', 'A'), ('Filling Pieces', 'A'),
  ('IRO', 'A'), ('J.Lindeberg', 'A'), ('Peuterey', 'A'), ('Zadig & Voltaire', 'A'),
  ('7 for all mankind', 'A'), ('STAND STUDIO', 'A'), ('Weekend Max Mara', 'A'),
  ('Karl Lagerfeld', 'B'), ('KARL LAGERFELD JEANS', 'B'), ('HUGO', 'B'),
  ('Calvin Klein', 'B'), ('Calvin Klein Jeans', 'B'), ('Calvin Klein Underwear', 'B'),
  ('Michael Kors', 'B'), ('MICHAEL Michael Kors', 'B'), ('ARMANI EXCHANGE', 'B'),
  ('EA7 Emporio Armani', 'B'), ('JOOP!', 'B'), ('JOOP! Jeans', 'B'), ('DIESEL', 'B'),
  ('La Martina', 'B'), ('Versace Jeans Couture', 'B'), ('Carlo Colucci', 'B'),
  ('Copenhagen Studios', 'B'), ('AMERICAN VINTAGE', 'B'), ('Just Cavalli', 'B'),
  ('Billionaire Boys Club', 'B'), ('True Religion', 'B'), ('GCDS', 'B'), ('ICECREAM', 'B'),
  ('LACOSTE', 'B'), ('Lauren Ralph Lauren', 'B'), ('MOSCHINO', 'B'),
  ('Bogner Fire + Ice', 'B'), ('ICEBREAKER', 'B'), ('BIKKEMBERGS', 'B'), ('BJÖRN BORG', 'B'),
  ('Plein Sport', 'B'), ('DENHAM', 'B'), ('Marimekko', 'B'), ('Swarovski', 'B'),
  ('Coccinelle', 'B'), ('FURLA', 'B'), ('ADIDAS PERFORMANCE', 'B'),
  ('ADIDAS SPORTSWEAR', 'B'), ('ADIDAS BY STELLA MCCARTNEY', 'B'),
  ('UNDER ARMOUR', 'B'), ('NIKE Underwear', 'B')
) seed(display_name, tier)
on conflict (brand_key) do update set
  display_name = excluded.display_name,
  tier = excluded.tier,
  updated_at = now();

create or replace view public.catalog_items with (security_invoker = true) as
select p.id, p.external_id, p.name, p.brand, p.product_url, p.image_urls, p.color_original,
  p.color_family, p.updated_at, s.slug as source,
  o.current_price, o.original_price, o.source_lpl_30, o.observed_min_30d, o.currency,
  (o.observed_min_30d is not null and o.current_price <= o.observed_min_30d) as below_observed_30d,
  case
    when o.source_lpl_30 > 0 and o.current_price < o.source_lpl_30
      then round((o.source_lpl_30 - o.current_price) * 100.0 / o.source_lpl_30, 2)
    else 0
  end as discount_pct,
  coalesce(array_agg(distinct category_value) filter (where category_value is not null), '{}') as categories,
  p.sizes, p.other_sizes, p.materials, p.patterns, p.features, p.styles, p.product_types,
  p.color_shade,
  (o.source_lpl_30 is not null and o.current_price <= o.source_lpl_30) as below_source_lpl_30d,
  p.first_seen_at,
  coalesce(array_agg(distinct c.name) filter (where c.name is not null), '{}') as category_names,
  coalesce(array_agg(distinct c.path) filter (where c.path is not null), '{}') as category_paths,
  p.is_premium,
  bt.tier as brand_tier
from public.products p
join public.sources s on s.id = p.source_id
join public.offers o on o.product_id = p.id
left join public.product_categories pc on pc.product_id = p.id
left join public.categories c on c.id = pc.category_id
left join lateral (values (c.name), (c.path)) category_values(category_value) on true
left join public.brand_tiers bt
  on bt.brand_key = lower(regexp_replace(trim(p.brand), '\s+', ' ', 'g'))
where p.active and s.active
group by p.id, s.slug, o.product_id, bt.tier;

create or replace view public.brand_tier_admin_items with (security_invoker = true) as
select
  lower(regexp_replace(trim(p.brand), '\s+', ' ', 'g')) as brand_key,
  min(p.brand) as display_name,
  count(*) filter (where p.active) as active_products,
  bt.tier,
  bt.updated_at,
  bt.updated_by
from public.products p
left join public.brand_tiers bt
  on bt.brand_key = lower(regexp_replace(trim(p.brand), '\s+', ' ', 'g'))
where trim(p.brand) <> ''
group by lower(regexp_replace(trim(p.brand), '\s+', ' ', 'g')), bt.tier, bt.updated_at, bt.updated_by;

revoke all on table public.brand_tier_admin_items from public, anon, authenticated;
grant select on table public.brand_tier_admin_items to service_role;

create or replace function public.catalog_item_matches(
  item public.catalog_items,
  filters jsonb,
  omit_group text default null
) returns boolean language sql stable security invoker set search_path = public as $$
  select
    (omit_group = 'brands' or coalesce(jsonb_array_length(filters->'brands'), 0) = 0 or item.brand in (select jsonb_array_elements_text(filters->'brands'))) and
    (omit_group = 'brandTiers' or coalesce(jsonb_array_length(filters->'brandTiers'), 0) = 0 or item.brand_tier in (select jsonb_array_elements_text(filters->'brandTiers'))) and
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
    (omit_group = 'premium' or coalesce((filters->>'isPremium')::boolean, false) = false or item.is_premium) and
    (omit_group = 'excludeBasics' or coalesce((filters->>'excludeBasics')::boolean, false) = false or not (
      item.category_names && public.catalog_excluded_basics_categories() or
      item.categories && public.catalog_excluded_basics_categories()
    )) and
    (omit_group = 'price' or filters->>'priceMin' is null or item.current_price >= (filters->>'priceMin')::integer) and
    (omit_group = 'price' or filters->>'priceMax' is null or item.current_price <= (filters->>'priceMax')::integer) and
    (filters->>'discountMin' is null or item.discount_pct >= (filters->>'discountMin')::numeric) and
    (coalesce((filters->>'belowObserved30d')::boolean, false) = false or
      case when filters->>'priceComparison' = 'source_lpl' then item.below_source_lpl_30d else item.below_observed_30d end) and
    (coalesce((filters->>'newOnly')::boolean, false) = false or item.first_seen_at >= now() - interval '30 days')
$$;

create or replace function public.catalog_brand_tier_facets(p_filters jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('value', tier, 'count', product_count) order by tier), '[]'::jsonb)
  from (
    select item.brand_tier as tier, count(*) as product_count
    from public.catalog_items item
    where item.brand_tier is not null
      and public.catalog_item_matches(item, p_filters, 'brandTiers')
    group by item.brand_tier
  ) counts;
$$;

revoke all on function public.catalog_brand_tier_facets(jsonb) from public, anon, authenticated;
grant execute on function public.catalog_brand_tier_facets(jsonb) to service_role;

create or replace function public.catalog_category_facets(p_filters jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  with matching_products as materialized (
    select i.id, i.category_paths
    from public.catalog_items i
    where public.catalog_item_matches(i, p_filters, 'categories')
      and (coalesce((p_filters->>'newOnly')::boolean, false) = false or i.first_seen_at >= now() - interval '30 days')
  ), counts as (
    select category_path, count(distinct product.id) as product_count
    from matching_products product cross join lateral unnest(product.category_paths) category_path
    group by category_path
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', category.id,
    'parentId', category.parent_id,
    'name', category.name,
    'level', category.level,
    'path', category.path,
    'count', counts.product_count
  ) order by category.level, category.name), '[]'::jsonb)
  from counts join public.categories category on category.path = counts.category_path
  where category.level between 2 and 4
    and category.path <> 'vyrams>premium'
    and counts.product_count > 0;
$$;

revoke all on function public.catalog_category_facets(jsonb) from public, anon, authenticated;
grant execute on function public.catalog_category_facets(jsonb) to service_role;

-- Improve only non-authoritative fallback assignments. Exact source breadcrumbs
-- are deliberately excluded by category_path_updated_at is null.
do $$
declare
  product record;
  value text;
  target_path text[];
begin
  for product in
    select p.id, lower(concat_ws(' ', p.name, array_to_string(coalesce(p.product_types, '{}'), ' '))) as classification_text
    from public.products p
    where p.active and p.category_path_updated_at is null
  loop
    value := product.classification_text;
    target_path := case
      when value ~ 'akiniai nuo saul' then array['Vyrams', 'Aksesuarai', 'Akiniai nuo saulės']
      when value ~ 'megzta kepur' then array['Vyrams', 'Aksesuarai', 'Kepurės', 'Megztos kepurės']
      when value ~ 'skrybėl' then array['Vyrams', 'Aksesuarai', 'Kepurės', 'Skrybėlės']
      when value ~ 'kuprinė' then array['Vyrams', 'Aksesuarai', 'Krepšiai ir kuprinės', 'Kuprinės']
      when value ~ 'tualeto reikmenų|kosmetikos krepš' then array['Vyrams', 'Aksesuarai', 'Piniginės ir kosmetinės']
      when value ~ 'pirkinių krepš|sportinis krepš|krepšys|rankinė' then array['Vyrams', 'Aksesuarai', 'Krepšiai ir kuprinės', 'Krepšiai']
      when value ~ 'laikrodis' then array['Vyrams', 'Aksesuarai', 'Laikrodžiai']
      when value ~ 'apyrank' then array['Vyrams', 'Aksesuarai', 'Juvelyriniai dirbiniai', 'Apyrankės']
      when value ~ 'grandinėl' then array['Vyrams', 'Aksesuarai', 'Juvelyriniai dirbiniai', 'Grandinėlės']
      when value ~ 'auskar|žiedas' then array['Vyrams', 'Aksesuarai', 'Juvelyriniai dirbiniai']
      when value ~ 'šalik|skara' then array['Vyrams', 'Aksesuarai', 'Šalikai ir šaliai']
      when value ~ 'raktų laikikl' then array['Vyrams', 'Aksesuarai']
      when value ~ 'sportbačiai be auliuko' then array['Vyrams', 'Batai', 'Sportbačiai', 'Sportbačiai žemu auliuku']
      when value ~ 'šlepet' then array['Vyrams', 'Batai', 'Atviri batai', 'Šlepetės']
      when value ~ 'auliniai batai' then array['Vyrams', 'Batai', 'Batai ir auliniai batai', 'Auliniai batai']
      when value ~ 'sportinės kojinės|kojinės' then array['Vyrams', 'Drabužiai', 'Apatiniai', 'Kojinės']
      else null
    end;
    if target_path is not null then
      perform public.record_product_category_path(product.id, to_jsonb(target_path), false);
    end if;
  end loop;
end $$;

-- Move the few surviving legacy links to a canonical category with the same
-- name, preferring the current accessories hierarchy, then remove dead rows.
insert into public.product_categories(product_id, category_id)
select link.product_id, canonical.id
from public.product_categories link
join public.categories legacy on legacy.id = link.category_id and legacy.path is null
join lateral (
  select current.id
  from public.categories current
  where current.path is not null and lower(current.name) = lower(legacy.name)
  order by
    (current.path like 'vyrams>aksesuarai>kepurės>%') desc,
    current.level desc,
    current.path
  limit 1
) canonical on true
on conflict do nothing;

delete from public.categories where path is null;
