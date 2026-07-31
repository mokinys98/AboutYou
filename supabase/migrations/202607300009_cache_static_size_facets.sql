-- The first static-size implementation still expanded the complete effective
-- view on every request. Keep override evaluation cheap and persist the small
-- distinct size payload separately from contextual facet counters.

create or replace view public.catalog_size_facets_read_effective as
with source_values as (
  select
    sf.product_id,
    coalesce(o.size_domain, sf.domain_key) as domain_key,
    sf.value_key as source_value_key,
    sf.display_label as source_display_label,
    sf.sort_order,
    o.size_value_overrides -> sf.display_label as value_override
  from public.catalog_size_facets_read sf
  left join public.catalog_size_classification_overrides o
    on o.product_id = sf.product_id
  where coalesce(o.exclude_from_size_filter, false) = false
), normalized as (
  select
    product_id,
    domain_key,
    public.catalog_size_domain_label(domain_key) as domain_label,
    case
      when value_override is null then source_value_key
      else public.catalog_size_value_key(
        coalesce(nullif(trim(value_override->>'label'), ''), source_display_label)
        || case
          when nullif(trim(value_override->>'sizeGroup'), '') is not null
            then '-' || trim(value_override->>'sizeGroup')
          else ''
        end
      )
    end as value_key,
    case
      when value_override is null then source_display_label
      else coalesce(nullif(trim(value_override->>'label'), ''), source_display_label)
        || case
          when nullif(trim(value_override->>'sizeGroup'), '') is not null
            then ' / ' || trim(value_override->>'sizeGroup')
          else ''
        end
    end as display_label,
    sort_order
  from source_values
)
select
  product_id,
  domain_key,
  domain_label,
  value_key,
  display_label,
  domain_key || ':' || value_key as token,
  sort_order
from normalized;

revoke all on table public.catalog_size_facets_read_effective
  from public, anon, authenticated;
grant select on table public.catalog_size_facets_read_effective
  to service_role;

create table if not exists public.catalog_static_size_facets_cache (
  singleton boolean primary key default true check (singleton),
  payload jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.catalog_static_size_facets_cache enable row level security;
revoke all on table public.catalog_static_size_facets_cache
  from public, anon, authenticated;
grant select, insert, update on table public.catalog_static_size_facets_cache
  to service_role;

create or replace function public.catalog_build_static_size_facets()
returns jsonb
language sql stable security definer
set search_path = public, pg_temp as $$
  with grouped as (
    select
      sf.domain_key,
      max(sf.domain_label) as domain_label,
      sf.value_key,
      max(sf.display_label) as display_label,
      sf.token,
      min(sf.sort_order) as sort_order
    from public.catalog_size_facets_read_effective sf
    group by sf.domain_key, sf.value_key, sf.token
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'value', grouped.token,
    'label', grouped.display_label,
    'domainKey', grouped.domain_key,
    'domainLabel', grouped.domain_label,
    'valueKey', grouped.value_key,
    'sortOrder', grouped.sort_order
  ) order by grouped.domain_key, grouped.sort_order, grouped.display_label), '[]'::jsonb)
  from grouped;
$$;

revoke all on function public.catalog_build_static_size_facets()
  from public, anon, authenticated;

create or replace function public.refresh_catalog_static_size_facets_cache()
returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  size_facets jsonb;
begin
  size_facets := public.catalog_build_static_size_facets();

  insert into public.catalog_static_size_facets_cache(singleton, payload)
  values (true, size_facets)
  on conflict (singleton) do update
  set payload = excluded.payload,
      updated_at = now();
end;
$$;

revoke all on function public.refresh_catalog_static_size_facets_cache()
  from public, anon, authenticated;

create or replace function public.catalog_grouped_size_facets(
  p_filters jsonb default '{}'::jsonb
) returns jsonb
language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(
    (
      select payload
      from public.catalog_static_size_facets_cache
      where singleton
    ),
    public.catalog_build_static_size_facets()
  );
$$;

revoke all on function public.catalog_grouped_size_facets(jsonb)
  from public, anon, authenticated;
grant execute on function public.catalog_grouped_size_facets(jsonb)
  to service_role;

create or replace function public.invalidate_catalog_facets_cache()
returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  size_facets jsonb;
begin
  perform public.refresh_catalog_static_size_facets_cache();

  select payload into size_facets
  from public.catalog_static_size_facets_cache
  where singleton;

  update public.catalog_facets_cache
  set payload = jsonb_set(
        jsonb_set(payload, '{sizes}', size_facets, true),
        '{otherSizes}',
        '[]'::jsonb,
        true
      ),
      created_at = now();
end;
$$;

revoke all on function public.invalidate_catalog_facets_cache()
  from public, anon, authenticated;
grant execute on function public.invalidate_catalog_facets_cache()
  to service_role;

-- Preserve the last usable contextual facet payload during catalog refresh.
-- Product rows refresh concurrently; static sizes are rebuilt and patched into
-- every existing payload without creating a cache-miss outage.
create or replace function public.rebuild_catalog_items_read_internal()
returns void
language plpgsql security definer
set search_path = public, pg_temp
set lock_timeout = '3s' as $$
begin
  execute 'refresh materialized view concurrently public.catalog_items_read';
  execute 'refresh materialized view concurrently public.catalog_item_facet_values_read';
  execute 'refresh materialized view concurrently public.catalog_size_facets_read';
  perform public.invalidate_catalog_facets_cache();
end;
$$;

revoke all on function public.rebuild_catalog_items_read_internal()
  from public, anon, authenticated, service_role;

-- Populate the dedicated size cache once. Future catalog requests only read
-- this single JSON row.
select public.invalidate_catalog_facets_cache();

update cron.job
set active = true
where jobname = 'catalog-read-model-refresh';

notify pgrst, 'reload schema';
