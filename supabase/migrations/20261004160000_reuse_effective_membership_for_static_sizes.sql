-- Reuse the just-refreshed effective size membership for the global size
-- dictionary. Grouping max/min twice gives the same result as grouping the
-- source effective view once, without re-evaluating size normalization.
-- Keep the phase labels from 20261004150000 for subsequent diagnostics.
-- This migration changes only the function; it does not start a refresh.
begin;

create or replace function public.invalidate_catalog_facets_cache()
returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_phase text := 'effective_size_membership';
  v_phase_started_at timestamptz := clock_timestamp();
  v_size_facets jsonb;
begin
  execute 'refresh materialized view public.catalog_effective_size_membership_read';

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
