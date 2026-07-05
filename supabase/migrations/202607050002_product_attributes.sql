alter table public.products
  add column if not exists sizes text[] not null default '{}',
  add column if not exists other_sizes text[] not null default '{}',
  add column if not exists materials text[] not null default '{}',
  add column if not exists patterns text[] not null default '{}',
  add column if not exists features text[] not null default '{}',
  add column if not exists styles text[] not null default '{}',
  add column if not exists product_types text[] not null default '{}';

create index if not exists products_sizes_idx on public.products using gin (sizes) where active;
create index if not exists products_materials_idx on public.products using gin (materials) where active;
create index if not exists products_product_types_idx on public.products using gin (product_types) where active;

update public.products
set product_types = array[trim(regexp_replace(name, '\s+[„“''"].*$', ''))]
where product_types = '{}' and trim(name) <> '';

insert into public.categories(slug, name) values
  ('marskineliai', 'Marškinėliai'), ('kelnes', 'Kelnės'), ('apatiniai', 'Apatiniai'),
  ('dzinsai', 'Džinsai'), ('striukes', 'Striukės'), ('marskiniai', 'Marškiniai'),
  ('treningo-dalys', 'Treningo dalys'), ('maudymosi-drabuziai', 'Maudymosi drabužiai'),
  ('megztiniai', 'Megztiniai'), ('kostiumai-ir-svarkai', 'Kostiumai ir švarkai'),
  ('paltai', 'Paltai'), ('proginiai', 'Proginiai'), ('isskirtiniai', 'Išskirtiniai')
on conflict (slug) do update set name = excluded.name;

-- Existing products inherit their category sync target immediately.
insert into public.categories(slug, name)
select 'target-' || md5(lower(t.label)), t.label
from public.sync_targets t
where t.kind = 'category'
  and not exists (select 1 from public.categories c where lower(c.name) = lower(t.label))
on conflict (slug) do update set name = excluded.name;

insert into public.product_categories(product_id, category_id)
select distinct stp.product_id, c.id
from public.sync_target_products stp
join public.sync_targets t on t.id = stp.target_id and t.kind = 'category'
join public.categories c on lower(c.name) = lower(t.label)
on conflict do nothing;

-- ABOUT YOU tile names contain the product kind; use it to restore broad clothing categories.
insert into public.product_categories(product_id, category_id)
select distinct p.id, c.id
from public.products p
join (values
  ('Marškinėliai', '(marškinėl|polo|berankov)'),
  ('Džinsai', 'džins'),
  ('Apatiniai', '(apatin|kojin|naktin|chalatas|trumpik)'),
  ('Striukės', '(striuk|parka|bomber|liemenė)'),
  ('Marškiniai', 'marškiniai'),
  ('Treningo dalys', '(džemper|trening|sportinės kelnės)'),
  ('Maudymosi drabužiai', '(maudym|glaud)'),
  ('Megztiniai', '(megztin|kardigan)'),
  ('Kostiumai ir švarkai', '(kostium|švark)'),
  ('Paltai', '(palt|lietpalt)'),
  ('Kelnės', '(keln|šort)')
) as rule(category_name, pattern) on p.name ~* rule.pattern
join public.categories c on c.name = rule.category_name
on conflict do nothing;

create or replace function public.record_catalog_batch(
  p_source_id uuid,
  p_target_id uuid,
  p_run_id uuid,
  p_products jsonb
) returns integer language plpgsql security definer set search_path = public as $$
declare
  item jsonb;
  v_product_id uuid;
  v_category text;
  v_category_id uuid;
  v_count integer := 0;
begin
  for item in select value from jsonb_array_elements(p_products)
  loop
    insert into public.products (
      source_id, external_id, name, brand, product_url, image_urls,
      color_original, color_family, sizes, other_sizes, materials, patterns,
      features, styles, product_types, active, last_seen_at, updated_at
    ) values (
      p_source_id, item->>'externalId', item->>'name', coalesce(item->>'brand', ''),
      item->>'productUrl', coalesce(item->'imageUrls', '[]'::jsonb), item->>'colorOriginal',
      coalesce(item->>'colorFamily', 'other'),
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
      color_family = excluded.color_family, sizes = excluded.sizes, other_sizes = excluded.other_sizes,
      materials = excluded.materials, patterns = excluded.patterns, features = excluded.features,
      styles = excluded.styles, product_types = excluded.product_types,
      active = true, last_seen_at = now(), updated_at = now()
    returning id into v_product_id;

    perform public.record_price_observation(
      v_product_id, (item->>'currentPrice')::integer,
      nullif(item->>'originalPrice', '')::integer, nullif(item->>'sourceLpl30', '')::integer,
      coalesce(item->>'currency', 'EUR')::char(3)
    );

    insert into public.sync_target_products(target_id, product_id, last_seen_run_id, missing_successful_runs, active)
    values (p_target_id, v_product_id, p_run_id, 0, true)
    on conflict (target_id, product_id) do update set
      last_seen_run_id = excluded.last_seen_run_id, missing_successful_runs = 0, active = true;

    for v_category in select jsonb_array_elements_text(coalesce(item->'categories', '[]'::jsonb))
    loop
      select id into v_category_id from public.categories where lower(name) = lower(v_category) limit 1;
      if v_category_id is null then
        insert into public.categories(slug, name) values ('category-' || md5(lower(v_category)), v_category)
        on conflict (slug) do update set name = excluded.name returning id into v_category_id;
      end if;
      insert into public.product_categories(product_id, category_id)
      values (v_product_id, v_category_id) on conflict do nothing;
    end loop;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

create or replace view public.catalog_items with (security_invoker = true) as
select p.id, p.external_id, p.name, p.brand, p.product_url, p.image_urls, p.color_original,
  p.color_family, p.updated_at, s.slug as source,
  o.current_price, o.original_price, o.source_lpl_30, o.observed_min_30d, o.currency,
  (o.observed_min_30d is not null and o.current_price <= o.observed_min_30d) as below_observed_30d,
  case when o.original_price > 0 then round((o.original_price - o.current_price) * 100.0 / o.original_price, 2) else 0 end as discount_pct,
  coalesce(array_agg(distinct c.name) filter (where c.name is not null), '{}') as categories,
  p.sizes, p.other_sizes, p.materials, p.patterns, p.features, p.styles, p.product_types
from public.products p
join public.sources s on s.id = p.source_id
join public.offers o on o.product_id = p.id
left join public.product_categories pc on pc.product_id = p.id
left join public.categories c on c.id = pc.category_id
where p.active and s.active
group by p.id, s.slug, o.product_id;

create or replace function public.catalog_facets() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'brands', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', brand, 'count', count(*)) x from public.catalog_items where brand <> '' group by brand) q),
    'categories', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from public.catalog_items, unnest(categories) value group by value) q),
    'colors', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', color_family, 'count', count(*)) x from public.catalog_items group by color_family) q),
    'sources', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', source, 'count', count(*)) x from public.catalog_items group by source) q),
    'sizes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from public.catalog_items, unnest(sizes) value group by value) q),
    'otherSizes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from public.catalog_items, unnest(other_sizes) value group by value) q),
    'materials', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from public.catalog_items, unnest(materials) value group by value) q),
    'patterns', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from public.catalog_items, unnest(patterns) value group by value) q),
    'features', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from public.catalog_items, unnest(features) value group by value) q),
    'styles', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from public.catalog_items, unnest(styles) value group by value) q),
    'productTypes', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', value, 'count', count(*)) x from public.catalog_items, unnest(product_types) value group by value) q),
    'price', (select jsonb_build_object('min', coalesce(min(current_price), 0), 'max', coalesce(max(current_price), 0)) from public.catalog_items)
  );
$$;
