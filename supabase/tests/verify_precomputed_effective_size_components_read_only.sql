-- Run in VPS SQL Editor after applying
-- 20261011200000_precompute_effective_size_components.sql.
-- Expected: one row, cron_active=false, view_owner=postgres,
-- and all four component flags true. This verifies the deployed definition,
-- not its execution time.
begin read only;
set local statement_timeout = '5s';

select
  clock_timestamp() as checked_at_utc,
  j.active as cron_active,
  pg_get_userbyid(c.relowner) as view_owner,
  position('normalized_components AS MATERIALIZED' in pg_get_viewdef(c.oid, true)) > 0
    as normalized_components_materialized,
  position('expanded_components AS MATERIALIZED' in pg_get_viewdef(c.oid, true)) > 0
    as expanded_components_materialized,
  position('prepared_components AS MATERIALIZED' in pg_get_viewdef(c.oid, true)) > 0
    as prepared_components_materialized,
  position('facet_components AS MATERIALIZED' in pg_get_viewdef(c.oid, true)) > 0
    as facet_components_materialized
from pg_class c
cross join cron.job j
where c.oid = 'public.catalog_size_facets_read_effective'::regclass
  and j.jobname = 'catalog-read-model-refresh';

rollback;
