-- Run in VPS SQL Editor after the one-time ANALYZE. Expected: one row;
-- active=false, live_rows close to estimated_rows, no refresh locks.
begin read only;

select
  clock_timestamp() as checked_at_utc,
  j.active as refresh_job_active,
  c.reltuples::bigint as estimated_rows,
  (select count(*) from public.catalog_items_read) as live_rows,
  pg_size_pretty(pg_relation_size(c.oid)) as heap_size,
  s.last_analyze,
  s.last_autovacuum,
  exists (
    select 1 from pg_locks l
    where (l.locktype = 'advisory'
      and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted)
      or (l.relation = c.oid
        and l.mode in ('ExclusiveLock', 'AccessExclusiveLock') and l.granted)
  ) as refresh_lock_now
from cron.job j
cross join pg_class c
join pg_stat_all_tables s on s.relid = c.oid
where j.jobname = 'catalog-read-model-refresh'
  and c.oid = 'public.catalog_items_read'::regclass;

rollback;
