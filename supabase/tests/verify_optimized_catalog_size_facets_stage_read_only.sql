-- Safe to run whether the stage materialized view is populated or not.
-- Expected: one row. Check stage_populated before running the separate exact
-- row-count query in verify_optimized_catalog_size_facets_stage_row_count_read_only.sql.
-- Do not reference the stage relation in a CASE expression: PostgreSQL checks
-- materialized-view population while planning, even for an unchosen CASE arm.
begin read only;
set local statement_timeout = '10s';

select
  clock_timestamp() as checked_at_utc,
  (select count(*) = 1 and bool_and(not j.active)
   from cron.job j
   where j.jobname = 'catalog-read-model-refresh'
     and j.schedule = '*/5 * * * *'
     and j.command ilike '%process_catalog_items_read_refresh()%')
    as cron_paused,
  c.relkind = 'm' as is_materialized_view,
  c.relispopulated as stage_populated,
  pg_get_userbyid(c.relowner) as stage_owner,
  c.reltuples::bigint as stage_estimated_rows,
  pg_size_pretty(pg_relation_size(c.oid)) as stage_heap_size,
  pg_get_viewdef(c.oid, true) like '%item_inputs AS MATERIALIZED%'
    as definition_uses_per_product_inputs
from pg_class c
where c.oid = 'public.catalog_size_facets_read_optimized_stage'::regclass;

rollback;
