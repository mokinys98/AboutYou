\set ON_ERROR_STOP on

-- Run only against an empty disposable PostgreSQL database. This fixture
-- supplies the relations that the migration depends on, then proves that a
-- jeans category never receives a bag size from the global dictionary.

create role anon;
create role authenticated;
create role service_role;

create table public.catalog_size_facets_read_effective (
  product_id bigint not null,
  domain_key text not null,
  domain_label text not null,
  value_key text not null,
  display_label text not null,
  token text not null,
  sort_order numeric not null
);

create table public.catalog_items_read_with_lpl (
  id bigint primary key,
  brand text not null,
  brand_tier text,
  category_paths text[] not null default '{}',
  categories text[] not null default '{}',
  category_names text[] not null default '{}',
  color_family text,
  color_shade text,
  source text,
  materials text[] not null default '{}',
  patterns text[] not null default '{}',
  features text[] not null default '{}',
  styles text[] not null default '{}',
  product_types text[] not null default '{}',
  is_premium boolean not null default false,
  current_price numeric not null,
  discount_pct numeric not null default 0,
  lpl_price_ratio numeric,
  below_source_lpl_30d boolean not null default false,
  below_observed_30d boolean not null default false,
  first_seen_at timestamptz not null default now()
);

create table public.catalog_static_size_facets_cache (
  singleton boolean primary key default true check (singleton),
  payload jsonb not null,
  updated_at timestamptz not null default now()
);

create table public.catalog_facets_cache (
  filters jsonb primary key,
  payload jsonb not null,
  created_at timestamptz not null default now()
);

create materialized view public.catalog_items_read as
select 1::bigint as id with no data;
create unique index catalog_items_read_test_idx
  on public.catalog_items_read(id);

create materialized view public.catalog_item_facet_values_read as
select 1::bigint as product_id with no data;
create unique index catalog_item_facet_values_read_test_idx
  on public.catalog_item_facet_values_read(product_id);

create materialized view public.catalog_size_facets_read as
select 1::bigint as product_id with no data;
create unique index catalog_size_facets_read_test_idx
  on public.catalog_size_facets_read(product_id);

create function public.catalog_excluded_basics_categories()
returns text[] language sql immutable as $$ select '{}'::text[] $$;

create function public.catalog_excluded_accessories_paths()
returns text[] language sql immutable as $$ select '{}'::text[] $$;

create function public.catalog_facets(p_filters jsonb default '{}'::jsonb)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'sizes', '[]'::jsonb,
    'otherSizes', '[]'::jsonb,
    'brands', '[]'::jsonb
  )
$$;

create function public.refresh_catalog_static_size_facets_cache()
returns void language plpgsql as $$
begin
  insert into public.catalog_static_size_facets_cache(singleton, payload)
  values (true, public.catalog_build_static_size_facets())
  on conflict (singleton) do update
  set payload = excluded.payload,
      updated_at = now();
end
$$;

\ir ../migrations/202607310001_restore_contextual_size_facets.sql

insert into public.catalog_items_read_with_lpl(
  id, brand, category_paths, categories, category_names, color_family,
  color_shade, source, current_price
) values
  (1, 'Jeans Brand', array['vyrams>drabužiai>džinsai'], array['Džinsai'],
    array['Džinsai'], 'blue', 'blue', 'aboutyou', 50),
  (2, 'Bag Brand', array['vyrams>aksesuarai>krepšiai'], array['Krepšiai'],
    array['Krepšiai'], 'black', 'black', 'aboutyou', 40);

insert into public.catalog_size_facets_read_effective(
  product_id, domain_key, domain_label, value_key, display_label, token, sort_order
) values
  (1, 'trousers', 'Kelnės ir džinsai', 'w32-l32', 'W32 / L32',
    'trousers:w32-l32', 32),
  (2, 'bags', 'Krepšiai ir kuprinės', 'one-size', 'Vienas dydis',
    'bags:one-size', 900000);

select public.refresh_catalog_static_size_facets_cache();

do $$
declare
  category_filters jsonb := jsonb_build_object(
    'categories', jsonb_build_array('vyrams>drabužiai>džinsai')
  );
  result jsonb;
  cached jsonb;
begin
  result := public.catalog_facets_cached(category_filters);

  if jsonb_array_length(result->'sizes') <> 1 then
    raise exception 'Expected one contextual jeans size, got %', result->'sizes';
  end if;

  if result->'sizes'->0->>'value' <> 'trousers:w32-l32' then
    raise exception 'Wrong contextual size payload: %', result->'sizes';
  end if;

  if (result->'sizes'->0->>'count')::integer <> 1 then
    raise exception 'Missing contextual product count: %', result->'sizes';
  end if;

  if result::text like '%bags:one-size%' then
    raise exception 'Bag size leaked into jeans category: %', result->'sizes';
  end if;

  select payload into cached
  from public.catalog_facets_cache
  where catalog_facets_cache.filters = category_filters;

  if cached is distinct from result then
    raise exception 'Exact category cache entry was not stored';
  end if;
end
$$;

select 'contextual_size_facets_test_ok' as result;
