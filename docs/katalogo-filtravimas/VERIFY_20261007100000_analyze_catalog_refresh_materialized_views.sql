-- Read-only verification for migration
-- supabase/migrations/20261007100000_analyze_catalog_refresh_materialized_views.sql
-- Run after the migration and again after a natural catalog refresh cycle.
-- Expected after migration: function_guard_passes = true.
-- Expected after a natural cycle: requested_version = completed_version,
-- last_status = 'clean', and each MV's last_analyze is recent and no later
-- than refresh_completed_at. Compare against the pre-migration timestamps if
-- checking whether the natural cycle ran ANALYZE.

begin read only;

select
  current_user as verifier,
  pg_get_userbyid(p.proowner) as function_owner,
  pg_get_userbyid(items.relowner) as catalog_items_owner,
  pg_get_userbyid(sizes.relowner) as catalog_size_facets_owner,
  position(
    'refresh materialized view concurrently public.catalog_items_read' in lower(pg_get_functiondef(p.oid))
  ) > 0
    and position(
      'analyze public.catalog_items_read' in lower(pg_get_functiondef(p.oid))
    ) > position(
      'refresh materialized view concurrently public.catalog_items_read' in lower(pg_get_functiondef(p.oid))
    )
    and position(
      'refresh materialized view concurrently public.catalog_item_facet_values_read' in lower(pg_get_functiondef(p.oid))
    ) > position(
      'analyze public.catalog_items_read' in lower(pg_get_functiondef(p.oid))
    )
    and position(
      'refresh materialized view concurrently public.catalog_size_facets_read' in lower(pg_get_functiondef(p.oid))
    ) > position(
      'refresh materialized view concurrently public.catalog_item_facet_values_read' in lower(pg_get_functiondef(p.oid))
    )
    and position(
      'refresh materialized view concurrently public.catalog_size_facets_read' in lower(pg_get_functiondef(p.oid))
    ) > 0
    and position(
      'analyze public.catalog_size_facets_read' in lower(pg_get_functiondef(p.oid))
    ) > position(
      'refresh materialized view concurrently public.catalog_size_facets_read' in lower(pg_get_functiondef(p.oid))
    )
    and position(
      'perform public.invalidate_catalog_facets_cache()' in lower(pg_get_functiondef(p.oid))
    ) > position(
      'analyze public.catalog_size_facets_read' in lower(pg_get_functiondef(p.oid))
    )
    and pg_get_userbyid(p.proowner) = pg_get_userbyid(items.relowner)
    and pg_get_userbyid(p.proowner) = pg_get_userbyid(sizes.relowner)
    as function_guard_passes
from pg_proc p
join pg_class items on items.oid = 'public.catalog_items_read'::regclass
join pg_class sizes on sizes.oid = 'public.catalog_size_facets_read'::regclass
where p.oid = 'public.rebuild_catalog_items_read_internal()'::regprocedure;

select
  pg_get_userbyid(p.proowner) = pg_get_userbyid(rebuild.proowner)
    as invalidate_owner_matches_rebuild_owner,
  position(
    'refresh materialized view concurrently public.catalog_effective_size_membership_read' in lower(pg_get_functiondef(p.oid))
  ) > 0
    and position('insert into public.catalog_static_size_facets_cache' in lower(pg_get_functiondef(p.oid))) > 0
    and position('delete from public.catalog_facets_cache' in lower(pg_get_functiondef(p.oid))) > 0
    and position('perform public.catalog_facets_cached' in lower(pg_get_functiondef(p.oid))) > 0
    and position('catalog refresh phase %s after %s ms' in lower(pg_get_functiondef(p.oid))) > 0
    as invalidate_guard_passes
from pg_proc p
join pg_proc rebuild
  on rebuild.oid = 'public.rebuild_catalog_items_read_internal()'::regprocedure
where p.oid = 'public.invalidate_catalog_facets_cache()'::regprocedure;

select
  state.requested_version,
  state.completed_version,
  state.last_status,
  state.refresh_completed_at,
  items.n_live_tup as catalog_items_estimated_rows,
  items.last_analyze as catalog_items_last_analyze,
  items.last_autoanalyze as catalog_items_last_autoanalyze,
  sizes.n_live_tup as catalog_size_facets_estimated_rows,
  sizes.last_analyze as catalog_size_facets_last_analyze,
  sizes.last_autoanalyze as catalog_size_facets_last_autoanalyze
from public.catalog_read_model_refresh_state state
left join pg_stat_all_tables items
  on items.relid = 'public.catalog_items_read'::regclass
left join pg_stat_all_tables sizes
  on sizes.relid = 'public.catalog_size_facets_read'::regclass
where state.singleton;

rollback;
