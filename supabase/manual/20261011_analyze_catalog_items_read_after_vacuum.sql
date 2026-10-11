-- One-time VPS Supabase SQL Editor maintenance while the catalog refresh is paused.
-- Refresh the badly stale planner statistics after the 2026-10-11 autovacuum.
-- Do not run if the 5-minute job has been resumed or any refresh lock remains.
begin;
set local statement_timeout = '30s';
set local lock_timeout = '2s';

do $$
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  if (select count(*) from cron.job j
      where j.jobname = 'catalog-read-model-refresh'
        and j.username = current_user
        and j.schedule = '*/5 * * * *'
        and j.command ilike '%process_catalog_items_read_refresh()%'
        and not j.active) <> 1 then
    raise exception 'Expected exactly one paused catalog refresh job';
  end if;

  if exists (
    select 1 from pg_locks l
    where (l.locktype = 'advisory'
      and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted)
      or (l.relation = 'public.catalog_items_read'::regclass
        and l.mode in ('ExclusiveLock', 'AccessExclusiveLock') and l.granted)
  ) then
    raise exception 'A catalog refresh lock is still held';
  end if;
end;
$$;

analyze public.catalog_items_read;

commit;
