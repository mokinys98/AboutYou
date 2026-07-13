-- Force strict LPL filtering after later view rewrites.
-- This must be newer than migrations that also recreate catalog_items.
create or replace view public.catalog_items with (security_invoker = true) as
select p.id, p.external_id, p.name, p.brand, p.product_url, p.image_urls, p.color_original,
  p.color_family, p.updated_at, s.slug as source,
  o.current_price, o.original_price, o.source_lpl_30, o.observed_min_30d, o.currency,
  (o.observed_min_30d is not null and o.current_price < o.observed_min_30d) as below_observed_30d,
  case
    when o.source_lpl_30 > 0 and o.current_price < o.source_lpl_30
      then round((o.source_lpl_30 - o.current_price) * 100.0 / o.source_lpl_30, 2)
    else 0
  end as discount_pct,
  coalesce(array_agg(distinct category_value) filter (where category_value is not null), '{}') as categories,
  p.sizes, p.other_sizes, p.materials, p.patterns, p.features, p.styles, p.product_types,
  p.color_shade,
  (o.source_lpl_30 is not null and o.current_price < o.source_lpl_30) as below_source_lpl_30d,
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
