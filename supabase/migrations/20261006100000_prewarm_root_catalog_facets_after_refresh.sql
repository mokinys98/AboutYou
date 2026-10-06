-- Populate the canonical unfiltered facet cache after catalog refresh.
-- This uses the same catalog_facets_cached('{}') path as the API request.
-- The cache row is written in the refresh transaction; a failure rolls back
-- the refresh rather than publishing a partially refreshed cache.
begin;

do $$
declare
  v_definition text;
  v_cache_definition text;
begin
  select lower(pg_get_functiondef(p.oid))
  into v_definition
  from pg_proc p
  where p.oid = 'public.invalidate_catalog_facets_cache()'::regprocedure
    and pg_get_userbyid(p.proowner) = current_user;

  select lower(pg_get_functiondef('public.catalog_facets_cached(jsonb)'::regprocedure))
  into v_cache_definition;

  if v_definition is null
    or position('refresh materialized view concurrently public.catalog_effective_size_membership_read' in v_definition) = 0
    or position('delete from public.catalog_facets_cache' in v_definition) = 0
    or position('perform public.catalog_facets_cached' in v_definition) > 0
    or position('when cache_filters = ''{}''::jsonb then public.catalog_root_facets()' in v_cache_definition) = 0
  then
    raise exception 'Unexpected cache invalidation function or owner; inspect VPS before applying';
  end if;
end;
$$;

create or replace function public.invalidate_catalog_facets_cache()
returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_phase text := 'effective_size_membership';
  v_phase_started_at timestamptz := clock_timestamp();
  v_size_facets jsonb;
begin
  execute 'refresh materialized view concurrently public.catalog_effective_size_membership_read';

  v_phase := 'static_size_facets_cache';
  v_phase_started_at := clock_timestamp();
  with grouped as (
    select
      sf.domain_key,
      max(sf.domain_label) as domain_label,
      sf.value_key,
      max(sf.display_label) as display_label,
      sf.token,
      min(sf.sort_order) as sort_order
    from public.catalog_effective_size_membership_read sf
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
  into v_size_facets
  from grouped;

  insert into public.catalog_static_size_facets_cache(singleton, payload)
  values (true, v_size_facets)
  on conflict (singleton) do update
  set payload = excluded.payload,
      updated_at = now();

  v_phase := 'facet_cache_delete';
  v_phase_started_at := clock_timestamp();
  delete from public.catalog_facets_cache;

  v_phase := 'root_facet_cache_prewarm';
  v_phase_started_at := clock_timestamp();
  perform public.catalog_facets_cached('{}'::jsonb);
exception
  when query_canceled then
    raise exception using errcode = '57014',
      message = format('catalog refresh phase %s after %s ms: %s', v_phase,
        round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000), SQLERRM);
  when others then
    raise exception using errcode = SQLSTATE,
      message = format('catalog refresh phase %s after %s ms: %s', v_phase,
        round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000), SQLERRM);
end;
$$;

commit;
