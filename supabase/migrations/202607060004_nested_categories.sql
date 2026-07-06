-- Preserve the ABOUT YOU breadcrumb as a real hierarchy. Legacy category rows
-- remain readable by name while exact paths are progressively backfilled by
-- the hourly product metadata job.
alter table public.categories add column if not exists parent_id uuid references public.categories(id) on delete cascade;
alter table public.categories add column if not exists level smallint check (level between 1 and 4);
alter table public.categories add column if not exists path text;
create unique index if not exists categories_path_unique_idx on public.categories(path) where path is not null;
create index if not exists categories_parent_idx on public.categories(parent_id) where parent_id is not null;

alter table public.products add column if not exists category_path_updated_at timestamptz;
create index if not exists products_category_path_pending_idx
  on public.products(source_id, id) where active and category_path_updated_at is null;

do $$
declare
  root_id uuid;
  root_name text;
  root_path text;
  root_category_id uuid;
begin
  select id into root_id from public.categories where lower(name) = 'vyrams' limit 1;
  if root_id is null then
    insert into public.categories(slug, name, level, path)
    values ('category-' || md5('vyrams'), 'Vyrams', 1, 'vyrams') returning id into root_id;
  else
    update public.categories set parent_id = null, level = 1, path = 'vyrams' where id = root_id;
  end if;

  foreach root_name in array array['Drabužiai', 'Batai', 'Aksesuarai', 'Sportas', 'Streetwear', 'Premium']
  loop
    root_path := 'vyrams>' || lower(root_name);
    select id into root_category_id from public.categories where lower(name) = lower(root_name) limit 1;
    if root_category_id is null then
      insert into public.categories(slug, name, parent_id, level, path)
      values ('category-' || md5(root_path), root_name, root_id, 2, root_path)
      returning id into root_category_id;
    else
      update public.categories set parent_id = root_id, level = 2, path = root_path where id = root_category_id;
    end if;
  end loop;
end $$;

create or replace function public.record_product_category_path(
  p_product_id uuid,
  p_path jsonb,
  p_exact boolean default false
) returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_names text[];
  v_name text;
  v_parent_id uuid := null;
  v_category_id uuid;
  v_path text := '';
  v_level integer := 0;
begin
  select array_agg(name order by ordinal)
  into v_names
  from (
    select regexp_replace(trim(value), '\s+', ' ', 'g') as name, ordinality as ordinal
    from jsonb_array_elements_text(coalesce(p_path, '[]'::jsonb)) with ordinality
    where trim(value) <> ''
    order by ordinality
    limit 4
  ) values_with_order;

  if cardinality(v_names) is null or cardinality(v_names) = 0 then return false; end if;
  if lower(v_names[1]) <> 'vyrams' then v_names := array_prepend('Vyrams', v_names); end if;
  if cardinality(v_names) > 4 then v_names := v_names[1:4]; end if;
  if cardinality(v_names) < 2 then return false; end if;

  if p_exact then
    delete from public.product_categories where product_id = p_product_id;
  else
    delete from public.product_categories pc using public.categories c
    where pc.product_id = p_product_id and pc.category_id = c.id and c.path is not null;
  end if;

  foreach v_name in array v_names
  loop
    v_level := v_level + 1;
    v_path := case when v_path = '' then lower(v_name) else v_path || '>' || lower(v_name) end;
    select id into v_category_id from public.categories where path = v_path;
    if v_category_id is null then
      insert into public.categories(slug, name, parent_id, level, path)
      values ('category-' || md5(v_path), v_name, v_parent_id, v_level, v_path)
      on conflict (path) where path is not null do update set
        name = excluded.name, parent_id = excluded.parent_id, level = excluded.level
      returning id into v_category_id;
    end if;
    insert into public.product_categories(product_id, category_id)
    values (p_product_id, v_category_id) on conflict do nothing;
    v_parent_id := v_category_id;
  end loop;
  return true;
end $$;

revoke all on function public.record_product_category_path(uuid, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.record_product_category_path(uuid, jsonb, boolean) to service_role;

create or replace function public.record_catalog_batch(
  p_source_id uuid,
  p_target_id uuid,
  p_run_id uuid,
  p_products jsonb
) returns integer language plpgsql security definer set search_path = public as $$
declare
  item jsonb;
  v_product_id uuid;
  v_count integer := 0;
  v_categories_exact boolean;
  v_category_path_updated_at timestamptz;
begin
  for item in select value from jsonb_array_elements(p_products)
  loop
    insert into public.products (
      source_id, external_id, name, brand, product_url, image_urls,
      color_original, color_family, color_shade, sizes, other_sizes, materials, patterns,
      features, styles, product_types, active, last_seen_at, updated_at
    ) values (
      p_source_id, item->>'externalId', item->>'name', coalesce(item->>'brand', ''),
      item->>'productUrl', coalesce(item->'imageUrls', '[]'::jsonb), item->>'colorOriginal',
      coalesce(item->>'colorFamily', 'other'), coalesce(item->>'colorShade', 'other'),
      array(select jsonb_array_elements_text(coalesce(item->'sizes', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'otherSizes', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'materials', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'patterns', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'features', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'styles', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'productTypes', '[]'::jsonb))),
      true, now(), now()
    )
    on conflict (source_id, external_id) do update set
      name = excluded.name, brand = excluded.brand, product_url = excluded.product_url,
      image_urls = excluded.image_urls, color_original = excluded.color_original,
      color_family = excluded.color_family, color_shade = excluded.color_shade,
      sizes = excluded.sizes, other_sizes = excluded.other_sizes, materials = excluded.materials,
      patterns = excluded.patterns, features = excluded.features, styles = excluded.styles,
      product_types = excluded.product_types, active = true, last_seen_at = now(), updated_at = now()
    returning id, category_path_updated_at into v_product_id, v_category_path_updated_at;

    perform public.record_price_observation(
      v_product_id, (item->>'currentPrice')::integer,
      nullif(item->>'originalPrice', '')::integer, nullif(item->>'sourceLpl30', '')::integer,
      coalesce(item->>'currency', 'EUR')::char(3)
    );

    insert into public.sync_target_products(target_id, product_id, last_seen_run_id, missing_successful_runs, active)
    values (p_target_id, v_product_id, p_run_id, 0, true)
    on conflict (target_id, product_id) do update set
      last_seen_run_id = excluded.last_seen_run_id, missing_successful_runs = 0, active = true;

    v_categories_exact := coalesce((item->>'categoriesExact')::boolean, false);
    if v_categories_exact or v_category_path_updated_at is null then
      if public.record_product_category_path(v_product_id, item->'categoryPath', v_categories_exact) and v_categories_exact then
        update public.products set category_path_updated_at = now() where id = v_product_id;
      end if;
    end if;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

grant execute on function public.record_catalog_batch(uuid, uuid, uuid, jsonb) to service_role;

create or replace function public.record_product_metadata_batch(p_products jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  item jsonb;
  v_product_id uuid;
  v_categories_exact boolean;
  v_count integer := 0;
begin
  for item in select value from jsonb_array_elements(p_products)
  loop
    v_product_id := (item->>'id')::uuid;
    update public.products set
      color_original = coalesce(nullif(item->>'colorOriginal', ''), color_original),
      color_family = case when nullif(item->>'colorOriginal', '') is not null then coalesce(nullif(item->>'colorFamily', ''), color_family) else color_family end,
      color_shade = case when nullif(item->>'colorOriginal', '') is not null then coalesce(nullif(item->>'colorShade', ''), color_shade) else color_shade end,
      sizes = case when jsonb_array_length(coalesce(item->'sizes', '[]')) > 0 then array(select jsonb_array_elements_text(item->'sizes')) else sizes end,
      other_sizes = case when jsonb_array_length(coalesce(item->'otherSizes', '[]')) > 0 then array(select jsonb_array_elements_text(item->'otherSizes')) else other_sizes end,
      materials = case when jsonb_array_length(coalesce(item->'materials', '[]')) > 0 then array(select jsonb_array_elements_text(item->'materials')) else materials end,
      patterns = case when jsonb_array_length(coalesce(item->'patterns', '[]')) > 0 then array(select jsonb_array_elements_text(item->'patterns')) else patterns end,
      features = case when jsonb_array_length(coalesce(item->'features', '[]')) > 0 then array(select jsonb_array_elements_text(item->'features')) else features end,
      styles = case when jsonb_array_length(coalesce(item->'styles', '[]')) > 0 then array(select jsonb_array_elements_text(item->'styles')) else styles end,
      product_types = case when jsonb_array_length(coalesce(item->'productTypes', '[]')) > 0 then array(select jsonb_array_elements_text(item->'productTypes')) else product_types end,
      metadata_updated_at = now(), updated_at = now()
    where id = v_product_id and active;
    if not found then continue; end if;

    v_categories_exact := coalesce((item->>'categoriesExact')::boolean, false);
    if public.record_product_category_path(v_product_id, item->'categoryPath', v_categories_exact) and v_categories_exact then
      update public.products set category_path_updated_at = now() where id = v_product_id;
    end if;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

revoke all on function public.record_product_metadata_batch(jsonb) from public, anon, authenticated;
grant execute on function public.record_product_metadata_batch(jsonb) to service_role;

create or replace view public.catalog_items with (security_invoker = true) as
select p.id, p.external_id, p.name, p.brand, p.product_url, p.image_urls, p.color_original,
  p.color_family, p.updated_at, s.slug as source,
  o.current_price, o.original_price, o.source_lpl_30, o.observed_min_30d, o.currency,
  (o.observed_min_30d is not null and o.current_price <= o.observed_min_30d) as below_observed_30d,
  case when o.original_price > 0 then round((o.original_price - o.current_price) * 100.0 / o.original_price, 2) else 0 end as discount_pct,
  coalesce(array_agg(distinct category_value) filter (where category_value is not null), '{}') as categories,
  p.sizes, p.other_sizes, p.materials, p.patterns, p.features, p.styles, p.product_types,
  p.color_shade,
  (coalesce(o.source_lpl_30, o.observed_min_30d) is not null and o.current_price <= coalesce(o.source_lpl_30, o.observed_min_30d)) as below_source_lpl_30d,
  p.first_seen_at,
  coalesce(array_agg(distinct c.name) filter (where c.name is not null), '{}') as category_names,
  coalesce(array_agg(distinct c.path) filter (where c.path is not null), '{}') as category_paths
from public.products p
join public.sources s on s.id = p.source_id
join public.offers o on o.product_id = p.id
left join public.product_categories pc on pc.product_id = p.id
left join public.categories c on c.id = pc.category_id
left join lateral (values (c.name), (c.path)) category_values(category_value) on true
where p.active and s.active
group by p.id, s.slug, o.product_id;

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
  where category.level between 2 and 4 and counts.product_count > 0;
$$;

grant execute on function public.catalog_category_facets(jsonb) to service_role;
