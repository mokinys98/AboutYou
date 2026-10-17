-- VPS Supabase SQL Editor preflight before the isolated stage concurrent refresh.
-- Expected: exactly one paused job, no active run/refresh lock, populated stage,
-- and all three valid indexes. Read-only; no production relation is modified.
begin read only;
set local statement_timeout = '5s';

select
  clock_timestamp() as checked_at_utc,
  (select count(*) = 1 and bool_and(not j.active)
   from cron.job j
   where j.jobname = 'catalog-read-model-refresh'
     and j.schedule = '*/5 * * * *'
     and j.command ilike '%process_catalog_items_read_refresh()%') as cron_paused,
  exists (
    select 1 from cron.job_run_details r
    join cron.job j on j.jobid = r.jobid
    where j.jobname = 'catalog-read-model-refresh'
      and r.status = 'running' and r.end_time is null
  ) as refresh_run_running,
  c.relispopulated as stage_populated,
  pg_get_userbyid(c.relowner) as stage_owner,
  (select count(*) = 3
       and bool_and(i.indisvalid and i.indisready)
       and bool_or(i.indisunique and
         i.indexrelid::regclass::text = 'catalog_size_facets_read_optimized_stage_unique_idx')
   from pg_index i
   where i.indrelid = c.oid
     and i.indexrelid::regclass::text in (
       'catalog_size_facets_read_optimized_stage_domain_idx',
       'catalog_size_facets_read_optimized_stage_token_idx',
       'catalog_size_facets_read_optimized_stage_unique_idx'
     )) as stage_indexes_valid,
  exists (
    select 1 from pg_locks l
    where (l.locktype = 'advisory'
      and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted)
      or (l.relation in (
        'public.catalog_items_read'::regclass,
        'public.catalog_item_facet_values_read'::regclass,
        'public.catalog_size_facets_read'::regclass,
        'public.catalog_effective_size_membership_read'::regclass,
        'public.catalog_size_facets_read_optimized_stage'::regclass
      ) and l.mode in ('ExclusiveLock', 'AccessExclusiveLock') and l.granted)
  ) as catalog_refresh_lock_now
from pg_class c
where c.oid = 'public.catalog_size_facets_read_optimized_stage'::regclass;

rollback;
