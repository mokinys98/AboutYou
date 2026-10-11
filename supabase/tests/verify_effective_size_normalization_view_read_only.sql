-- Run in VPS Supabase SQL Editor after applying
-- 20261011190000_deduplicate_effective_size_normalization.sql.
-- Expected: one row, cron_active=false, view_optimized=true,
-- source_materialized=true, distinct_inputs_materialized=true,
-- normalized_inputs_materialized=true. This checks deployment, not speed.
begin read only;
set local statement_timeout = '5s';

select
  clock_timestamp() as checked_at_utc,
  j.active as cron_active,
  pg_get_userbyid(c.relowner) as view_owner,
  position('source_values AS MATERIALIZED' in pg_get_viewdef(c.oid, true)) > 0
    as source_materialized,
  position('distinct_inputs AS MATERIALIZED' in pg_get_viewdef(c.oid, true)) > 0
    as distinct_inputs_materialized,
  position('normalized_inputs AS MATERIALIZED' in pg_get_viewdef(c.oid, true)) > 0
    as normalized_inputs_materialized,
  position('JOIN normalized_inputs' in pg_get_viewdef(c.oid, true)) > 0
    as view_optimized
from pg_class c
cross join cron.job j
where c.oid = 'public.catalog_size_facets_read_effective'::regclass
  and j.jobname = 'catalog-read-model-refresh';

rollback;
