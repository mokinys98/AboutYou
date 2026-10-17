-- Read-only verification after applying
-- 20261017180000_index_optimized_catalog_size_stage.sql.
-- Expected: stage_populated=true, cron_active=false, duplicate_key_rows=0,
-- three expected indexes valid/ready, and only service_role has SELECT.
begin read only;
set local statement_timeout = '10s';

select
  clock_timestamp() as checked_at_utc,
  c.relispopulated as stage_populated,
  pg_get_userbyid(c.relowner) as stage_owner,
  j.active as cron_active,
  (select count(*) from public.catalog_size_facets_read_optimized_stage) as stage_rows,
  (select count(*) - count(distinct (product_id, token))
     from public.catalog_size_facets_read_optimized_stage) as duplicate_key_rows,
  has_table_privilege('anon', c.oid, 'SELECT') as anon_can_select,
  has_table_privilege('authenticated', c.oid, 'SELECT') as authenticated_can_select,
  has_table_privilege('service_role', c.oid, 'SELECT') as service_role_can_select
from pg_class c
cross join cron.job j
where c.oid = 'public.catalog_size_facets_read_optimized_stage'::regclass
  and j.jobname = 'catalog-read-model-refresh';

select
  ci.relname as index_name,
  i.indisunique as is_unique,
  i.indisvalid as is_valid,
  i.indisready as is_ready,
  pg_get_indexdef(i.indexrelid) as index_definition,
  pg_size_pretty(pg_relation_size(i.indexrelid)) as index_size
from pg_index i
join pg_class ci on ci.oid = i.indexrelid
where i.indrelid = 'public.catalog_size_facets_read_optimized_stage'::regclass
order by ci.relname;

rollback;
