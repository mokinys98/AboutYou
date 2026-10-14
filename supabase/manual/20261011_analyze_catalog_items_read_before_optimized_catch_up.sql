-- VPS SQL Editor: refresh catalog_items_read planner statistics after the
-- failed 12-minute catch-up. Its rolled-back refresh left reltuples=175606
-- while the live row count was 104588 at 19:04 UTC.
-- Run once while the 5-minute cron job is paused, then use the separate
-- read-only verification before the next catch-up attempt.
begin;
set local statement_timeout = '2min';
set local lock_timeout = '3s';

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
      or (l.relation in (
          'public.catalog_items_read'::regclass,
          'public.catalog_item_facet_values_read'::regclass,
          'public.catalog_size_facets_read'::regclass,
          'public.catalog_effective_size_membership_read'::regclass
        ) and l.mode in ('ExclusiveLock', 'AccessExclusiveLock') and l.granted)
  ) then
    raise exception 'A catalog refresh lock is still held';
  end if;
end;
$$;

analyze public.catalog_items_read;

commit;
