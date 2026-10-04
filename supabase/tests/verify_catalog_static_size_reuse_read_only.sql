-- Run in VPS Supabase SQL Editor after applying
-- 20261004160000_reuse_effective_membership_for_static_sizes.sql.
-- This does not start or change a refresh. The first three flags should be
-- true immediately. After a successful cron cycle, catalog_current and
-- cache_matches_membership should also be true.
begin read only;

with definition as (
  select lower(pg_get_functiondef('public.invalidate_catalog_facets_cache()'::regprocedure)) as sql_body
), state as (
  select requested_version, completed_version, last_status,
    last_duration_ms, last_error, refresh_started_at, refresh_completed_at
  from public.catalog_read_model_refresh_state
  where singleton
)
select
  position('from public.catalog_effective_size_membership_read sf' in definition.sql_body) > 0
    as membership_reused_for_static_sizes,
  position('perform public.refresh_catalog_static_size_facets_cache()' in definition.sql_body) = 0
    as old_static_rebuild_removed,
  position('catalog refresh phase' in definition.sql_body) > 0 as phase_diagnostics_retained,
  state.requested_version,
  state.completed_version,
  state.requested_version = state.completed_version as catalog_current,
  state.last_status,
  state.last_duration_ms,
  state.last_error,
  state.refresh_started_at,
  state.refresh_completed_at,
  case when state.requested_version = state.completed_version then
    cache.payload = (
      select coalesce(jsonb_agg(jsonb_build_object(
        'value', grouped.token,
        'label', grouped.display_label,
        'domainKey', grouped.domain_key,
        'domainLabel', grouped.domain_label,
        'valueKey', grouped.value_key,
        'sortOrder', grouped.sort_order
      ) order by grouped.domain_key, grouped.sort_order, grouped.display_label), '[]'::jsonb)
      from (
        select sf.domain_key,
          max(sf.domain_label) as domain_label,
          sf.value_key,
          max(sf.display_label) as display_label,
          sf.token,
          min(sf.sort_order) as sort_order
        from public.catalog_effective_size_membership_read sf
        group by sf.domain_key, sf.value_key, sf.token
      ) grouped
    )
  else null end as cache_matches_membership
from definition cross join state
left join public.catalog_static_size_facets_cache cache on cache.singleton;

rollback;
