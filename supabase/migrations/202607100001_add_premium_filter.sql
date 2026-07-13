alter table public.products
  add column if not exists is_premium boolean not null default false;

create index if not exists products_is_premium_idx
  on public.products (is_premium) where active and is_premium;

update public.products product
set is_premium = true
from public.product_detail_raw raw
where raw.product_id = product.id
  and (
    exists (
      select 1
      from jsonb_array_elements(
        case
          when jsonb_typeof(raw.payload->'imagesSection'->'badges') = 'array'
            then raw.payload->'imagesSection'->'badges'
          else '[]'::jsonb
        end
      ) badge
      where lower(trim(badge->'tracker'->>'contextKey')) = 'product.badges.premium'
         or lower(trim(badge->'type'->'productAttribute'->>'label')) = 'premium'
    )
    or lower(trim(coalesce(raw.payload->'hotProductSection'->'infoBox'->>'subline', ''))) like 'premium %'
  );

create or replace function public.preserve_product_detail_metadata() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.metadata_updated_at is not null
     and new.metadata_updated_at is not distinct from old.metadata_updated_at then
    new.color_original := old.color_original;
    new.color_family := old.color_family;
    new.color_shade := old.color_shade;
    new.sizes := old.sizes;
    new.other_sizes := old.other_sizes;
    new.materials := old.materials;
    new.patterns := old.patterns;
    new.features := old.features;
    new.styles := old.styles;
    new.product_types := old.product_types;
    new.is_premium := old.is_premium;
  end if;
  return new;
end $$;

create or replace function public.complete_product_detail(
  p_product_id uuid,
  p_lease_token uuid,
  p_parser_version integer,
  p_payload jsonb,
  p_payload_hash text,
  p_source_endpoint text,
  p_result jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_section jsonb;
  v_option jsonb;
  v_categories_exact boolean := coalesce((p_result->>'categoriesExact')::boolean, false);
begin
  if not exists (
    select 1 from public.product_detail_sync
    where product_id = p_product_id and status = 'processing'
      and lease_token = p_lease_token and lease_until >= now() and parser_version = p_parser_version
  ) then
    raise exception 'Product detail lease is missing or expired';
  end if;
  if jsonb_typeof(p_payload) <> 'object' or p_payload_hash !~ '^[0-9a-f]{64}$'
     or trim(p_source_endpoint) = '' then
    raise exception 'Invalid product detail payload';
  end if;
  if jsonb_array_length(coalesce(p_result->'sections', '[]'::jsonb)) <> 4 then
    raise exception 'Every supported product detail section must have a terminal state';
  end if;

  insert into public.product_detail_raw(product_id, payload, payload_hash, fetched_at, source_endpoint, parser_version)
  values (p_product_id, p_payload, p_payload_hash, now(), p_source_endpoint, p_parser_version)
  on conflict (product_id) do update set
    payload = case when product_detail_raw.payload_hash is distinct from excluded.payload_hash then excluded.payload else product_detail_raw.payload end,
    payload_hash = excluded.payload_hash,
    fetched_at = excluded.fetched_at,
    source_endpoint = excluded.source_endpoint,
    parser_version = excluded.parser_version;

  delete from public.product_detail_sections where product_id = p_product_id;
  for v_section in select value from jsonb_array_elements(p_result->'sections') loop
    insert into public.product_detail_sections(
      product_id, section_key, source_label, status, source_type, position, items, parser_version, fetched_at
    ) values (
      p_product_id, v_section->>'key', v_section->>'sourceLabel', v_section->>'status',
      nullif(v_section->>'sourceType', ''), (v_section->>'position')::integer,
      coalesce(v_section->'items', '[]'::jsonb), p_parser_version, now()
    );
  end loop;

  delete from public.product_color_options where product_id = p_product_id;
  for v_option in select value from jsonb_array_elements(coalesce(p_result->'colorOptions', '[]'::jsonb)) with ordinality loop
    insert into public.product_color_options(product_id, position, external_id, label, url, selected)
    values (
      p_product_id, coalesce((v_option->>'position')::integer, 0), nullif(v_option->>'externalId', ''),
      v_option->>'label', nullif(v_option->>'url', ''), coalesce((v_option->>'selected')::boolean, false)
    );
  end loop;

  delete from public.product_size_options where product_id = p_product_id;
  for v_option in select value from jsonb_array_elements(coalesce(p_result->'sizeOptions', '[]'::jsonb)) loop
    insert into public.product_size_options(
      product_id, external_id, position, label, size_group, selected, selectable, availability
    ) values (
      p_product_id, v_option->>'externalId', (v_option->>'position')::integer, v_option->>'label',
      nullif(v_option->>'group', ''), coalesce((v_option->>'selected')::boolean, false),
      (v_option->>'selectable')::boolean, nullif(v_option->>'availability', '')
    );
  end loop;

  update public.products set
    image_urls = coalesce(p_result->'imageUrls', '[]'::jsonb),
    color_original = nullif(p_result->>'colorOriginal', ''),
    color_family = coalesce(nullif(p_result->>'colorFamily', ''), 'other'),
    color_shade = coalesce(nullif(p_result->>'colorShade', ''), 'other'),
    sizes = array(select jsonb_array_elements_text(coalesce(p_result->'sizes', '[]'::jsonb))),
    other_sizes = array(select jsonb_array_elements_text(coalesce(p_result->'otherSizes', '[]'::jsonb))),
    materials = array(select jsonb_array_elements_text(coalesce(p_result->'materials', '[]'::jsonb))),
    patterns = array(select jsonb_array_elements_text(coalesce(p_result->'patterns', '[]'::jsonb))),
    features = array(select jsonb_array_elements_text(coalesce(p_result->'features', '[]'::jsonb))),
    styles = array(select jsonb_array_elements_text(coalesce(p_result->'styles', '[]'::jsonb))),
    product_types = array(select jsonb_array_elements_text(coalesce(p_result->'productTypes', '[]'::jsonb))),
    is_premium = coalesce((p_result->>'isPremium')::boolean, false),
    detail_checked_at = now(), detail_last_error = null,
    metadata_updated_at = now(), updated_at = now()
  where id = p_product_id and active;
  if not found then raise exception 'Active product not found'; end if;

  if public.record_product_category_path(p_product_id, p_result->'categoryPath', v_categories_exact)
     and v_categories_exact then
    update public.products set category_path_updated_at = now() where id = p_product_id;
  end if;

  update public.product_detail_sync set
    status = 'complete', parser_version = p_parser_version,
    static_synced_at = now(), availability_synced_at = now(), attempt_count = 0,
    next_attempt_at = now() + interval '24 hours', lease_token = null, lease_until = null,
    last_error_code = null, last_http_status = null, updated_at = now()
  where product_id = p_product_id and lease_token = p_lease_token;
end $$;

revoke all on function public.complete_product_detail(uuid, uuid, integer, jsonb, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.complete_product_detail(uuid, uuid, integer, jsonb, text, text, jsonb) to service_role;

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
  (o.source_lpl_30 is not null and o.current_price < o.source_lpl_30) as below_source_lpl_30d,
  p.first_seen_at,
  coalesce(array_agg(distinct c.name) filter (where c.name is not null), '{}') as category_names,
  coalesce(array_agg(distinct c.path) filter (where c.path is not null), '{}') as category_paths,
  p.is_premium
from public.products p
join public.sources s on s.id = p.source_id
join public.offers o on o.product_id = p.id
left join public.product_categories pc on pc.product_id = p.id
left join public.categories c on c.id = pc.category_id
left join lateral (values (c.name), (c.path)) category_values(category_value) on true
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
    (omit_group = 'premium' or coalesce((filters->>'isPremium')::boolean, false) = false or item.is_premium) and
    (omit_group = 'price' or filters->>'priceMin' is null or item.current_price >= (filters->>'priceMin')::integer) and
    (omit_group = 'price' or filters->>'priceMax' is null or item.current_price <= (filters->>'priceMax')::integer) and
    (filters->>'discountMin' is null or item.discount_pct >= (filters->>'discountMin')::numeric) and
    (coalesce((filters->>'belowObserved30d')::boolean, false) = false or
      case when filters->>'priceComparison' = 'source_lpl' then item.below_source_lpl_30d else item.below_observed_30d end) and
    (coalesce((filters->>'newOnly')::boolean, false) = false or item.first_seen_at >= now() - interval '30 days')
$$;

create or replace function public.catalog_facets(p_filters jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  with filter_values as (
    select
      array(select jsonb_array_elements_text(coalesce(p_filters->'brands', '[]'::jsonb))) as brands,
      array(select jsonb_array_elements_text(coalesce(p_filters->'categories', '[]'::jsonb))) as categories,
      array(select jsonb_array_elements_text(coalesce(p_filters->'colors', '[]'::jsonb))) as colors,
      array(select jsonb_array_elements_text(coalesce(p_filters->'colorShades', '[]'::jsonb))) as color_shades,
      array(select jsonb_array_elements_text(coalesce(p_filters->'sources', '[]'::jsonb))) as sources,
      array(select jsonb_array_elements_text(coalesce(p_filters->'sizes', '[]'::jsonb))) as sizes,
      array(select jsonb_array_elements_text(coalesce(p_filters->'otherSizes', '[]'::jsonb))) as other_sizes,
      array(select jsonb_array_elements_text(coalesce(p_filters->'materials', '[]'::jsonb))) as materials,
      array(select jsonb_array_elements_text(coalesce(p_filters->'patterns', '[]'::jsonb))) as patterns,
      array(select jsonb_array_elements_text(coalesce(p_filters->'features', '[]'::jsonb))) as features,
      array(select jsonb_array_elements_text(coalesce(p_filters->'styles', '[]'::jsonb))) as styles,
      array(select jsonb_array_elements_text(coalesce(p_filters->'productTypes', '[]'::jsonb))) as product_types,
      coalesce((p_filters->>'isPremium')::boolean, false) as is_premium,
      nullif(p_filters->>'priceMin', '')::integer as price_min,
      nullif(p_filters->>'priceMax', '')::integer as price_max,
      nullif(p_filters->>'discountMin', '')::numeric as discount_min,
      coalesce((p_filters->>'belowObserved30d')::boolean, false) as below_minimum,
      coalesce(p_filters->>'priceComparison', 'observed') as price_comparison
  ), checks as materialized (
    select i.*,
      cardinality(f.brands) = 0 or i.brand = any(f.brands) as brand_ok,
      cardinality(f.categories) = 0 or i.categories && f.categories as category_ok,
      cardinality(f.colors) = 0 or i.color_family = any(f.colors) as color_ok,
      cardinality(f.color_shades) = 0 or i.color_shade = any(f.color_shades) as color_shade_ok,
      cardinality(f.sources) = 0 or i.source = any(f.sources) as source_ok,
      cardinality(f.sizes) = 0 or i.sizes && f.sizes as size_ok,
      cardinality(f.other_sizes) = 0 or i.other_sizes && f.other_sizes as other_size_ok,
      cardinality(f.materials) = 0 or i.materials && f.materials as material_ok,
      cardinality(f.patterns) = 0 or i.patterns && f.patterns as pattern_ok,
      cardinality(f.features) = 0 or i.features && f.features as feature_ok,
      cardinality(f.styles) = 0 or i.styles && f.styles as style_ok,
      cardinality(f.product_types) = 0 or i.product_types && f.product_types as product_type_ok,
      not f.is_premium or i.is_premium as premium_ok,
      (f.price_min is null or i.current_price >= f.price_min) and (f.price_max is null or i.current_price <= f.price_max) as price_ok,
      (f.discount_min is null or i.discount_pct >= f.discount_min) and
        (not f.below_minimum or case when f.price_comparison = 'source_lpl' then i.below_source_lpl_30d else i.below_observed_30d end) as common_ok
    from public.catalog_items i cross join filter_values f
  ), base as materialized (
    select c.*,
      (not brand_ok)::integer + (not category_ok)::integer + (not color_ok)::integer +
      (not color_shade_ok)::integer + (not source_ok)::integer + (not size_ok)::integer +
      (not other_size_ok)::integer + (not material_ok)::integer + (not pattern_ok)::integer +
      (not feature_ok)::integer + (not style_ok)::integer + (not product_type_ok)::integer +
      (not premium_ok)::integer + (not price_ok)::integer + (not common_ok)::integer as failed_groups
    from checks c
  )
  select jsonb_build_object(
    'brands', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', brand, 'count', count(*)) x from base where brand <> '' and failed_groups - (not brand_ok)::integer = 0 group by brand) q),
    'categories', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(categories) value where failed_groups - (not category_ok)::integer = 0 group by value) q),
    'colors', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', color_family, 'count', count(*)) x from base where failed_groups - (not color_ok)::integer = 0 group by color_family) q),
    'colorShades', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', color_shade, 'count', count(*)) x from base where failed_groups - (not color_shade_ok)::integer = 0 group by color_shade) q),
    'sources', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', source, 'count', count(*)) x from base where failed_groups - (not source_ok)::integer = 0 group by source) q),
    'sizes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(sizes) value where failed_groups - (not size_ok)::integer = 0 group by value) q),
    'otherSizes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(other_sizes) value where failed_groups - (not other_size_ok)::integer = 0 group by value) q),
    'materials', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(materials) value where failed_groups - (not material_ok)::integer = 0 group by value) q),
    'patterns', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(patterns) value where failed_groups - (not pattern_ok)::integer = 0 group by value) q),
    'features', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(features) value where failed_groups - (not feature_ok)::integer = 0 group by value) q),
    'styles', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(styles) value where failed_groups - (not style_ok)::integer = 0 group by value) q),
    'productTypes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from base cross join lateral unnest(product_types) value where failed_groups - (not product_type_ok)::integer = 0 group by value) q),
    'premium', (select jsonb_build_object('count', count(*)) from base where is_premium and failed_groups - (not premium_ok)::integer = 0),
    'price', (select jsonb_build_object('min', coalesce(min(current_price), 0), 'max', coalesce(max(current_price), 0)) from base where failed_groups - (not price_ok)::integer = 0)
  );
$$;

grant execute on function public.catalog_facets(jsonb) to service_role;

create or replace function public.catalog_news_facets(p_filters jsonb default '{}'::jsonb) returns jsonb
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
      public.catalog_item_matches(i, p_filters, 'premium') as match_premium,
      public.catalog_item_matches(i, p_filters, 'price') as match_price
    from public.catalog_items i
    where i.first_seen_at >= now() - interval '30 days'
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
    'premium', (select jsonb_build_object('count', count(*)) from base where is_premium and match_premium),
    'price', (select jsonb_build_object('min', coalesce(min(current_price), 0), 'max', coalesce(max(current_price), 0)) from base where match_price)
  );
$$;

grant execute on function public.catalog_news_facets(jsonb) to service_role;
