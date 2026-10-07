-- Refresh planner statistics after the catalog materialized views are rebuilt.
-- This keeps the existing refresh order, phase reporting, membership refresh,
-- and cache invalidation/prewarm behavior. It does not change the 5-minute
-- caller timeout and does not start a refresh during migration application.
begin;

do $$
declare
  v_rebuild_definition text;
  v_invalidate_definition text;
  v_function_owner oid;
begin
  select p.proowner, lower(pg_get_functiondef(p.oid))
  into v_function_owner, v_rebuild_definition
  from pg_proc p
  where p.oid = 'public.rebuild_catalog_items_read_internal()'::regprocedure
    and pg_get_userbyid(p.proowner) = current_user;

  select lower(pg_get_functiondef(p.oid))
  into v_invalidate_definition
  from pg_proc p
  where p.oid = 'public.invalidate_catalog_facets_cache()'::regprocedure
    and pg_get_userbyid(p.proowner) = current_user;

  if v_rebuild_definition is null
    -- Exact inspected live definition; stop if production has customized it.
    or md5(v_rebuild_definition) <> '9550e4f8105b660870670d3493b01b2b'
    or position('refresh materialized view concurrently public.catalog_items_read' in v_rebuild_definition) = 0
    or position('refresh materialized view concurrently public.catalog_item_facet_values_read' in v_rebuild_definition) = 0
    or position('refresh materialized view concurrently public.catalog_size_facets_read' in v_rebuild_definition) = 0
    or position('perform public.invalidate_catalog_facets_cache()' in v_rebuild_definition) = 0
    or position('catalog refresh phase %s after %s ms' in v_rebuild_definition) = 0
    or position('set lock_timeout' in v_rebuild_definition) = 0
    or v_invalidate_definition is null
    or position('refresh materialized view concurrently public.catalog_effective_size_membership_read' in v_invalidate_definition) = 0
    or position('insert into public.catalog_static_size_facets_cache' in v_invalidate_definition) = 0
    or position('delete from public.catalog_facets_cache' in v_invalidate_definition) = 0
    or position('perform public.catalog_facets_cached' in v_invalidate_definition) = 0
  then
    raise exception 'Unexpected catalog refresh function, phase guards, or owner; inspect VPS before applying';
  end if;

  if not exists (
    select 1
    from pg_class c
    where c.oid in (
      'public.catalog_items_read'::regclass,
      'public.catalog_size_facets_read'::regclass
    )
      and c.relkind = 'm'
      and c.relispopulated
      and c.relowner = v_function_owner
  ) or (
    select count(*)
    from pg_class c
    where c.oid in (
      'public.catalog_items_read'::regclass,
      'public.catalog_size_facets_read'::regclass
    )
      and c.relkind = 'm'
      and c.relispopulated
      and c.relowner = v_function_owner
  ) <> 2 then
    raise exception 'Expected populated refresh materialized views owned by the refresh function owner';
  end if;
end;
$$;

create or replace function public.rebuild_catalog_items_read_internal()
returns void
language plpgsql security definer
set search_path = public, pg_temp
set lock_timeout = '3s' as $$
declare
  v_phase text := 'catalog_items_read';
  v_phase_started_at timestamptz := clock_timestamp();
begin
  execute 'refresh materialized view concurrently public.catalog_items_read';
  execute 'analyze public.catalog_items_read';

  v_phase := 'catalog_item_facet_values_read';
  v_phase_started_at := clock_timestamp();
  execute 'refresh materialized view concurrently public.catalog_item_facet_values_read';

  v_phase := 'catalog_size_facets_read';
  v_phase_started_at := clock_timestamp();
  execute 'refresh materialized view concurrently public.catalog_size_facets_read';
  execute 'analyze public.catalog_size_facets_read';

  v_phase := 'invalidate_catalog_facets_cache';
  v_phase_started_at := clock_timestamp();
  perform public.invalidate_catalog_facets_cache();
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
