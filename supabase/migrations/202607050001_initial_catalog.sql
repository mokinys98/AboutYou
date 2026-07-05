create extension if not exists pgcrypto;

create type public.team_role as enum ('admin', 'viewer');
create type public.sync_target_kind as enum ('category', 'brand', 'search');
create type public.sync_run_status as enum ('running', 'success', 'partial', 'failed');

create table public.team_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  role public.team_role not null default 'viewer',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.sources (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  base_url text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.sources (slug, name, base_url)
values ('aboutyou-lt', 'ABOUT YOU Lietuva', 'https://www.aboutyou.lt');

create table public.sync_targets (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references public.sources(id),
  kind public.sync_target_kind not null,
  label text not null,
  url text not null unique check (url ~ '^https:\/\/([a-z0-9-]+\.)?aboutyou\.lt\/'),
  enabled boolean not null default true,
  priority integer not null default 100,
  requested_at timestamptz,
  last_started_at timestamptz,
  last_success_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references public.sources(id),
  external_id text not null,
  name text not null,
  brand text not null default '',
  product_url text not null,
  image_urls jsonb not null default '[]'::jsonb,
  color_original text,
  color_family text not null default 'other' check (color_family in ('black','white','grey','brown','beige','red','orange','yellow','green','blue','purple','pink','silver','gold','multicolor','other')),
  active boolean not null default true,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source_id, external_id)
);

create table public.offers (
  product_id uuid primary key references public.products(id) on delete cascade,
  current_price integer not null check (current_price >= 0),
  original_price integer check (original_price >= 0),
  source_lpl_30 integer check (source_lpl_30 >= 0),
  observed_min_30d integer check (observed_min_30d >= 0),
  currency char(3) not null default 'EUR',
  updated_at timestamptz not null default now()
);

create table public.daily_prices (
  product_id uuid not null references public.products(id) on delete cascade,
  observed_date date not null default current_date,
  min_price integer not null,
  max_price integer not null,
  last_price integer not null,
  source_lpl_30 integer,
  observations smallint not null default 1,
  updated_at timestamptz not null default now(),
  primary key (product_id, observed_date)
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null
);

create table public.product_categories (
  product_id uuid not null references public.products(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete cascade,
  primary key (product_id, category_id)
);

create table public.sync_runs (
  id uuid primary key default gen_random_uuid(),
  target_id uuid not null references public.sync_targets(id) on delete cascade,
  status public.sync_run_status not null default 'running',
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  pages_count integer not null default 0,
  products_count integer not null default 0,
  error text
);

create table public.sync_target_products (
  target_id uuid not null references public.sync_targets(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  last_seen_run_id uuid references public.sync_runs(id) on delete set null,
  missing_successful_runs smallint not null default 0,
  active boolean not null default true,
  primary key (target_id, product_id)
);

create index products_brand_idx on public.products (brand) where active;
create index products_color_idx on public.products (color_family) where active;
create index products_updated_idx on public.products (updated_at desc, id) where active;
create index offers_price_idx on public.offers (current_price, product_id);
create index offers_min30_idx on public.offers (observed_min_30d, product_id);
create index daily_prices_date_idx on public.daily_prices (observed_date);
create index sync_targets_due_idx on public.sync_targets (enabled, priority, requested_at);

create or replace function public.record_price_observation(
  p_product_id uuid,
  p_current_price integer,
  p_original_price integer default null,
  p_source_lpl_30 integer default null,
  p_currency char(3) default 'EUR'
) returns void language plpgsql security definer set search_path = public as $$
declare v_min integer;
begin
  insert into public.daily_prices(product_id, observed_date, min_price, max_price, last_price, source_lpl_30)
  values (p_product_id, current_date, p_current_price, p_current_price, p_current_price, p_source_lpl_30)
  on conflict (product_id, observed_date) do update set
    min_price = least(daily_prices.min_price, excluded.min_price),
    max_price = greatest(daily_prices.max_price, excluded.max_price),
    last_price = excluded.last_price,
    source_lpl_30 = excluded.source_lpl_30,
    observations = daily_prices.observations + 1,
    updated_at = now();

  select min(min_price) into v_min from public.daily_prices
  where product_id = p_product_id and observed_date >= current_date - 29;

  insert into public.offers(product_id, current_price, original_price, source_lpl_30, observed_min_30d, currency)
  values (p_product_id, p_current_price, p_original_price, p_source_lpl_30, v_min, p_currency)
  on conflict (product_id) do update set
    current_price = excluded.current_price,
    original_price = excluded.original_price,
    source_lpl_30 = excluded.source_lpl_30,
    observed_min_30d = excluded.observed_min_30d,
    currency = excluded.currency,
    updated_at = now();
end $$;

create or replace function public.finish_sync_run(
  p_run_id uuid,
  p_status public.sync_run_status,
  p_pages_count integer,
  p_products_count integer,
  p_error text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_target_id uuid;
begin
  select target_id into v_target_id from public.sync_runs where id = p_run_id;
  update public.sync_runs set status = p_status, finished_at = now(), pages_count = p_pages_count,
    products_count = p_products_count, error = p_error where id = p_run_id;

  if p_status = 'success' then
    update public.sync_target_products set
      missing_successful_runs = case when last_seen_run_id = p_run_id then 0 else missing_successful_runs + 1 end,
      active = case when last_seen_run_id = p_run_id then true else missing_successful_runs + 1 < 2 end
    where target_id = v_target_id;

    update public.products p set active = exists (
      select 1 from public.sync_target_products stp where stp.product_id = p.id and stp.active
    ) where exists (select 1 from public.sync_target_products x where x.product_id = p.id and x.target_id = v_target_id);

    update public.sync_targets set last_success_at = now(), last_error = null, requested_at = null, updated_at = now()
    where id = v_target_id;
  else
    update public.sync_targets set last_error = p_error, updated_at = now() where id = v_target_id;
  end if;
end $$;

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
      color_original, color_family, active, last_seen_at, updated_at
    ) values (
      p_source_id, item->>'externalId', item->>'name', coalesce(item->>'brand', ''),
      item->>'productUrl', coalesce(item->'imageUrls', '[]'::jsonb), item->>'colorOriginal',
      coalesce(item->>'colorFamily', 'other'), true, now(), now()
    )
    on conflict (source_id, external_id) do update set
      name = excluded.name, brand = excluded.brand, product_url = excluded.product_url,
      image_urls = excluded.image_urls, color_original = excluded.color_original,
      color_family = excluded.color_family, active = true, last_seen_at = now(), updated_at = now()
    returning id into v_product_id;

    perform public.record_price_observation(
      v_product_id,
      (item->>'currentPrice')::integer,
      nullif(item->>'originalPrice', '')::integer,
      nullif(item->>'sourceLpl30', '')::integer,
      coalesce(item->>'currency', 'EUR')::char(3)
    );

    insert into public.sync_target_products(target_id, product_id, last_seen_run_id, missing_successful_runs, active)
    values (p_target_id, v_product_id, p_run_id, 0, true)
    on conflict (target_id, product_id) do update set
      last_seen_run_id = excluded.last_seen_run_id, missing_successful_runs = 0, active = true;

    for v_category in select jsonb_array_elements_text(coalesce(item->'categories', '[]'::jsonb))
    loop
      insert into public.categories(slug, name)
      values (trim(both '-' from regexp_replace(lower(v_category), '[^a-z0-9]+', '-', 'g')), v_category)
      on conflict (slug) do update set name = excluded.name
      returning id into v_category_id;
      insert into public.product_categories(product_id, category_id)
      values (v_product_id, v_category_id) on conflict do nothing;
    end loop;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

create or replace function public.cleanup_price_history() returns bigint language sql security definer set search_path = public as $$
  with deleted as (delete from public.daily_prices where observed_date < current_date - 89 returning 1)
  select count(*) from deleted;
$$;

create view public.catalog_items with (security_invoker = true) as
select p.id, p.external_id, p.name, p.brand, p.product_url, p.image_urls, p.color_original,
  p.color_family, p.updated_at, s.slug as source,
  o.current_price, o.original_price, o.source_lpl_30, o.observed_min_30d, o.currency,
  (o.observed_min_30d is not null and o.current_price <= o.observed_min_30d) as below_observed_30d,
  case when o.original_price > 0 then round((o.original_price - o.current_price) * 100.0 / o.original_price, 2) else 0 end as discount_pct,
  coalesce(array_agg(distinct c.name) filter (where c.name is not null), '{}') as categories
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
    'categories', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', category, 'count', count(*)) x from public.catalog_items, unnest(categories) category group by category) q),
    'colors', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', color_family, 'count', count(*)) x from public.catalog_items group by color_family) q),
    'sources', (select coalesce(jsonb_agg(x order by x->>'value'), '[]') from (select jsonb_build_object('value', source, 'count', count(*)) x from public.catalog_items group by source) q),
    'price', (select jsonb_build_object('min', coalesce(min(current_price), 0), 'max', coalesce(max(current_price), 0)) from public.catalog_items)
  );
$$;

alter table public.team_members enable row level security;
alter table public.sources enable row level security;
alter table public.sync_targets enable row level security;
alter table public.products enable row level security;
alter table public.offers enable row level security;
alter table public.daily_prices enable row level security;
alter table public.categories enable row level security;
alter table public.product_categories enable row level security;
alter table public.sync_runs enable row level security;
alter table public.sync_target_products enable row level security;

-- The service-role key used by the API and sync worker bypasses RLS. Authenticated clients
-- receive no direct table access; the Hono API is the only catalog data boundary.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant execute on all functions in schema public to service_role;
