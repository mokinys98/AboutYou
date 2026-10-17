-- Run after the controlled SQL Editor refresh. Expected: one row with
-- outcome='refreshed', phase_count=9 and all *_ok columns true.
begin read only;
set local statement_timeout = '5s';

with latest as (
  select run_id, started_at, outcome, duration_ms, target_version
  from public.catalog_refresh_runs
  order by started_at desc, run_id desc
  limit 1
), phase_summary as (
  select
    count(p.phase_id) as phase_count,
    count(*) filter (where p.outcome = 'success') as successful_phases,
    array_agg(p.phase order by p.phase_id) as phase_order
  from latest r
  left join public.catalog_refresh_phases p on p.run_id = r.run_id
)
select
  r.run_id,
  r.started_at,
  r.outcome,
  r.duration_ms,
  r.target_version,
  r.outcome = 'refreshed' as outcome_ok,
  p.phase_count,
  p.successful_phases,
  p.phase_order,
  p.phase_count = 9 and p.successful_phases = 9 as phase_count_ok,
  p.phase_order = array[
    'catalog_items_read',
    'catalog_items_read_analyze',
    'catalog_item_facet_values_read',
    'catalog_size_facets_read',
    'catalog_size_facets_read_analyze',
    'effective_size_membership',
    'static_size_facets_cache',
    'facet_cache_delete',
    'root_facet_cache_prewarm'
  ]::text[] as phase_order_ok,
  s.completed_version >= r.target_version as version_completed_ok,
  (select count(*) = 1 and coalesce(bool_and(not j.active), false)
   from cron.job j where j.jobname = 'catalog-read-model-refresh') as cron_still_paused_ok
from latest r
cross join phase_summary p
cross join public.catalog_read_model_refresh_state s
where s.singleton;

rollback;
