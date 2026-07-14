create table public.catalog_facets_cache (
  filters jsonb primary key,
  payload jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.catalog_facets_cache enable row level security;
revoke all on table public.catalog_facets_cache from public, anon, authenticated;
grant select, insert, update, delete on table public.catalog_facets_cache to service_role;

create or replace function public.catalog_facets_cached(p_filters jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  result jsonb;
begin
  select payload into result
  from public.catalog_facets_cache
  where filters = p_filters;

  if found then
    return result;
  end if;

  result := public.catalog_facets(p_filters);
  insert into public.catalog_facets_cache(filters, payload)
  values (p_filters, result)
  on conflict (filters) do update set payload = excluded.payload, created_at = now();
  return result;
end;
$$;

revoke all on function public.catalog_facets_cached(jsonb) from public, anon, authenticated;
grant execute on function public.catalog_facets_cached(jsonb) to service_role;

create or replace function public.refresh_catalog_items_read() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pg_advisory_xact_lock(hashtext('catalog_items_read_refresh'));
  execute 'refresh materialized view concurrently public.catalog_items_read';
  execute 'refresh materialized view concurrently public.catalog_item_facet_values_read';
  delete from public.catalog_facets_cache;
  insert into public.catalog_facets_cache(filters, payload)
  values ('{}'::jsonb, public.catalog_facets('{}'::jsonb));
end;
$$;

revoke all on function public.refresh_catalog_items_read() from public, anon, authenticated;
grant execute on function public.refresh_catalog_items_read() to service_role;

insert into public.catalog_facets_cache(filters, payload)
values ('{}'::jsonb, public.catalog_facets('{}'::jsonb));

notify pgrst, 'reload schema';
