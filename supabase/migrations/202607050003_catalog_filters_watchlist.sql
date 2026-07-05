create or replace function public.normalize_color_shade(value text) returns text
language sql immutable parallel safe as $$
  select case
    when lower(coalesce(value, '')) ~ 'off[ -]?white|balta su|ne visai balta' then 'off_white'
    when lower(coalesce(value, '')) ~ 'charcoal|antracit' then 'charcoal'
    when lower(coalesce(value, '')) ~ 'burgund|bordo|vyno raud' then 'burgundy'
    when lower(coalesce(value, '')) ~ 'turkio|turquoise|türkis' then 'turquoise'
    when lower(coalesce(value, '')) ~ 'vario|copper|kupfer' then 'copper'
    when lower(coalesce(value, '')) ~ 'rūdžių|rudziu|rust|rost' then 'rust'
    when lower(coalesce(value, '')) ~ 'garsty|mustard|senf' then 'mustard'
    when lower(coalesce(value, '')) ~ 'alyvuog|olive|oliv' then 'olive'
    when lower(coalesce(value, '')) ~ 'chaki|khaki' then 'khaki'
    when lower(coalesce(value, '')) ~ 'teal|žalsvai mėl|zalsvai mel|petrol' then 'teal'
    when lower(coalesce(value, '')) ~ 'mėt|mint' then 'mint'
    when lower(coalesce(value, '')) ~ 'tamsiai mėl|tamsiai mel|navy|marine' then 'navy'
    when lower(coalesce(value, '')) ~ 'alyvin|lilac|lila' then 'lilac'
    when lower(coalesce(value, '')) ~ 'rožinio aukso|rose gold|dusty rose|sendinta rož' then 'rose'
    when lower(coalesce(value, '')) ~ 'kremin|cream|ivory|dramblio kaulo' then 'cream'
    when lower(coalesce(value, '')) ~ 'taupe|pilkai rud' then 'taupe'
    when lower(coalesce(value, '')) ~ 'camel|kupranug' then 'camel'
    when lower(coalesce(value, '')) ~ 'smė|smel|beige' then 'beige'
    when lower(coalesce(value, '')) ~ 'juod|black|schwarz' then 'black'
    when lower(coalesce(value, '')) ~ 'balt|white|weiß|weiss' then 'white'
    when lower(coalesce(value, '')) ~ 'pilk|grey|gray|grau' then 'grey'
    when lower(coalesce(value, '')) ~ 'rud|brown|braun' then 'brown'
    when lower(coalesce(value, '')) ~ 'raud|red|rot' then 'red'
    when lower(coalesce(value, '')) ~ 'oran|orange' then 'orange'
    when lower(coalesce(value, '')) ~ 'gelton|yellow|gelb' then 'yellow'
    when lower(coalesce(value, '')) ~ 'žal|zal|green|grün|grun' then 'green'
    when lower(coalesce(value, '')) ~ 'mėlyn|melyn|blue|blau' then 'blue'
    when lower(coalesce(value, '')) ~ 'violet|purple' then 'purple'
    when lower(coalesce(value, '')) ~ 'rož|roz|pink|rosa' then 'pink'
    when lower(coalesce(value, '')) ~ 'sidabr|silver|silber' then 'silver'
    when lower(coalesce(value, '')) ~ 'auks|gold' then 'gold'
    when lower(coalesce(value, '')) ~ 'multi|įvair|ivair|spalvot|bunt' then 'multicolor'
    else 'other'
  end
$$;

alter table public.products add column if not exists color_shade text not null default 'other';
alter table public.products drop constraint if exists products_color_shade_check;
alter table public.products add constraint products_color_shade_check check (color_shade in (
  'black','white','off_white','cream','beige','taupe','grey','charcoal','brown','camel','copper','rust',
  'red','burgundy','orange','yellow','mustard','green','olive','khaki','mint','teal','turquoise','blue',
  'navy','purple','lilac','pink','rose','silver','gold','multicolor','other'
));
update public.products set color_shade = public.normalize_color_shade(color_original);
update public.products set color_family = case
  when color_shade in ('white','off_white') then 'white'
  when color_shade in ('cream','beige') then 'beige'
  when color_shade in ('grey','charcoal') then 'grey'
  when color_shade in ('brown','camel','copper','taupe') then 'brown'
  when color_shade in ('red','burgundy') then 'red'
  when color_shade in ('orange','rust') then 'orange'
  when color_shade in ('yellow','mustard') then 'yellow'
  when color_shade in ('green','olive','khaki','mint','teal') then 'green'
  when color_shade in ('blue','navy','turquoise') then 'blue'
  when color_shade in ('purple','lilac') then 'purple'
  when color_shade in ('pink','rose') then 'pink'
  else color_shade
end
where color_shade <> 'other';
create index if not exists products_color_shade_idx on public.products (color_shade) where active;

create or replace function public.set_product_color_shade() returns trigger language plpgsql as $$
begin
  new.color_shade := public.normalize_color_shade(new.color_original);
  return new;
end $$;
drop trigger if exists products_color_shade_trigger on public.products;
create trigger products_color_shade_trigger before insert or update of color_original on public.products
for each row execute function public.set_product_color_shade();

create table if not exists public.product_watches (
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, product_id)
);
create index if not exists product_watches_user_created_idx on public.product_watches (user_id, created_at desc);
alter table public.product_watches enable row level security;
revoke all on public.product_watches from anon, authenticated;
grant all on public.product_watches to service_role;

create or replace view public.catalog_items with (security_invoker = true) as
select p.id, p.external_id, p.name, p.brand, p.product_url, p.image_urls, p.color_original,
  p.color_family, p.updated_at, s.slug as source,
  o.current_price, o.original_price, o.source_lpl_30, o.observed_min_30d, o.currency,
  (o.observed_min_30d is not null and o.current_price <= o.observed_min_30d) as below_observed_30d,
  case when o.original_price > 0 then round((o.original_price - o.current_price) * 100.0 / o.original_price, 2) else 0 end as discount_pct,
  coalesce(array_agg(distinct c.name) filter (where c.name is not null), '{}') as categories,
  p.sizes, p.other_sizes, p.materials, p.patterns, p.features, p.styles, p.product_types,
  p.color_shade,
  (coalesce(o.source_lpl_30, o.observed_min_30d) is not null and o.current_price <= coalesce(o.source_lpl_30, o.observed_min_30d)) as below_source_lpl_30d
from public.products p
join public.sources s on s.id = p.source_id
join public.offers o on o.product_id = p.id
left join public.product_categories pc on pc.product_id = p.id
left join public.categories c on c.id = pc.category_id
where p.active and s.active
group by p.id, s.slug, o.product_id;

create or replace function public.catalog_item_matches(
  item public.catalog_items,
  filters jsonb,
  omit_group text default null
) returns boolean language sql stable security invoker set search_path = public as $$
  select
    (omit_group = 'brands' or coalesce(jsonb_array_length(filters->'brands'), 0) = 0 or item.brand in (select jsonb_array_elements_text(filters->'brands'))) and
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
    (omit_group = 'price' or filters->>'priceMin' is null or item.current_price >= (filters->>'priceMin')::integer) and
    (omit_group = 'price' or filters->>'priceMax' is null or item.current_price <= (filters->>'priceMax')::integer) and
    (filters->>'discountMin' is null or item.discount_pct >= (filters->>'discountMin')::numeric) and
    (coalesce((filters->>'belowObserved30d')::boolean, false) = false or
      case when filters->>'priceComparison' = 'source_lpl' then item.below_source_lpl_30d else item.below_observed_30d end)
$$;

drop function if exists public.catalog_facets();
create or replace function public.catalog_facets(p_filters jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  with base as materialized (
    select i.*,
      public.catalog_item_matches(i, p_filters, 'brands') as match_brands,
      public.catalog_item_matches(i, p_filters, 'categories') as match_categories,
      public.catalog_item_matches(i, p_filters, 'colors') as match_colors,
      public.catalog_item_matches(i, p_filters, 'colorShades') as match_color_shades,
      public.catalog_item_matches(i, p_filters, 'sources') as match_sources,
      public.catalog_item_matches(i, p_filters, 'sizes') as match_sizes,
      public.catalog_item_matches(i, p_filters, 'otherSizes') as match_other_sizes,
      public.catalog_item_matches(i, p_filters, 'materials') as match_materials,
      public.catalog_item_matches(i, p_filters, 'patterns') as match_patterns,
      public.catalog_item_matches(i, p_filters, 'features') as match_features,
      public.catalog_item_matches(i, p_filters, 'styles') as match_styles,
      public.catalog_item_matches(i, p_filters, 'productTypes') as match_product_types,
      public.catalog_item_matches(i, p_filters, 'price') as match_price
    from public.catalog_items i
  )
  select jsonb_build_object(
    'brands', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', brand, 'count', count(*)) x from base where brand <> '' and match_brands group by brand) q),
    'categories', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(categories) value where match_categories group by value) q),
    'colors', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', color_family, 'count', count(*)) x from base where match_colors group by color_family) q),
    'colorShades', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', color_shade, 'count', count(*)) x from base where match_color_shades group by color_shade) q),
    'sources', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', source, 'count', count(*)) x from base where match_sources group by source) q),
    'sizes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(sizes) value where match_sizes group by value) q),
    'otherSizes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(other_sizes) value where match_other_sizes group by value) q),
    'materials', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(materials) value where match_materials group by value) q),
    'patterns', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(patterns) value where match_patterns group by value) q),
    'features', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(features) value where match_features group by value) q),
    'styles', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(styles) value where match_styles group by value) q),
    'productTypes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(product_types) value where match_product_types group by value) q),
    'price', (select jsonb_build_object('min', coalesce(min(current_price), 0), 'max', coalesce(max(current_price), 0)) from base where match_price)
  );
$$;

grant execute on function public.catalog_facets(jsonb) to service_role;
