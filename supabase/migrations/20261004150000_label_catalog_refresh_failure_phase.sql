-- Preserve the existing refresh order and cache behavior while recording the
-- phase that fails. process_catalog_items_read_refresh() already stores a
-- caught error in catalog_read_model_refresh_state.last_error. No refresh is
-- started by this migration.
begin;

create or replace function public.invalidate_catalog_facets_cache()
returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_phase text := 'effective_size_membership';
  v_phase_started_at timestamptz := clock_timestamp();
begin
  execute 'refresh materialized view public.catalog_effective_size_membership_read';
  v_phase := 'static_size_facets_cache';
  v_phase_started_at := clock_timestamp();
  perform public.refresh_catalog_static_size_facets_cache();
  v_phase := 'facet_cache_delete';
  v_phase_started_at := clock_timestamp();
  delete from public.catalog_facets_cache;
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
  v_phase := 'catalog_item_facet_values_read';
  v_phase_started_at := clock_timestamp();
  execute 'refresh materialized view concurrently public.catalog_item_facet_values_read';
  v_phase := 'catalog_size_facets_read';
  v_phase_started_at := clock_timestamp();
  execute 'refresh materialized view concurrently public.catalog_size_facets_read';
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
