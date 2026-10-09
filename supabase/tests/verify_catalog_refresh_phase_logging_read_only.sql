-- Read-only verification for 20261007200200_instrument_catalog_refresh_phase_timings.sql.
-- Expected: all three functions remain SECURITY DEFINER and owned by postgres;
-- all phase markers are present; the process function sets the run correlation id.
with functions as (
  select
    p.oid as function_oid,
    p.oid::regprocedure::text as function_signature,
    pg_get_userbyid(p.proowner) as owner,
    p.prosecdef as security_definer,
    p.proconfig as function_settings,
    lower(pg_get_functiondef(p.oid)) as definition
  from pg_proc p
  where p.oid in (
    'public.process_catalog_items_read_refresh()'::regprocedure,
    'public.rebuild_catalog_items_read_internal()'::regprocedure,
    'public.invalidate_catalog_facets_cache()'::regprocedure
  )
)
select
  function_signature,
  owner,
  security_definer,
  function_settings,
  case
    when function_oid = 'public.process_catalog_items_read_refresh()'::regprocedure then
      position('catalog_refresh_run run_id=' in definition) > 0
    else position('catalog_refresh_phase run_id=' in definition) > 0
  end as emits_expected_logs,
  case
    when function_oid = 'public.process_catalog_items_read_refresh()'::regprocedure then
      position('app.catalog_refresh_run_id' in definition) > 0
      and position('catalog_refresh_run run_id=' in definition) > 0
    when function_oid = 'public.rebuild_catalog_items_read_internal()'::regprocedure then
      position('catalog_items_read_analyze' in definition) > 0
      and position('catalog_item_facet_values_read' in definition) > 0
      and position('catalog_size_facets_read_analyze' in definition) > 0
    when function_oid = 'public.invalidate_catalog_facets_cache()'::regprocedure then
      position('effective_size_membership' in definition) > 0
      and position('static_size_facets_cache' in definition) > 0
      and position('facet_cache_delete' in definition) > 0
      and position('root_facet_cache_prewarm' in definition) > 0
    else false
  end as expected_phase_markers_present
from functions
order by function_signature;

-- The state query verifies that routine refresh state remains readable.
-- It does not itself show phase logs; inspect PostgreSQL logs for messages
-- beginning with `catalog_refresh_phase run_id=` and `catalog_refresh_run run_id=`.
select
  requested_version,
  completed_version,
  last_status,
  last_duration_ms,
  last_error,
  refresh_started_at,
  refresh_completed_at
from public.catalog_read_model_refresh_state
where singleton;
