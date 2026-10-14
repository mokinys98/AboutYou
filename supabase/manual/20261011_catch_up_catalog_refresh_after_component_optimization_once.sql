-- VPS SQL Editor: one controlled catch-up after verifying the 9.01-second
-- effective-size source plan and the fresh catalog_items_read ANALYZE.
-- Run this file only once while the 5-minute cron remains paused. SQL Editor
-- can time out before PostgreSQL finishes; never retry based on its UI alone.
-- The JSON status must be 'refreshed'; 'failed', 'busy', or 'clean' is not success.
begin;
set local statement_timeout = '12min';
set local lock_timeout = '3s';

do $$
declare
  v_estimated_rows float8;
  v_live_rows bigint;
  v_completed_version bigint;
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

  if md5(pg_get_viewdef('public.catalog_size_facets_read_effective'::regclass, true))
      <> '88c25cab7939592911a1f1a045b772e9' then
    raise exception 'Unexpected effective-size view definition; inspect VPS before catch-up';
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

  select s.completed_version into v_completed_version
  from public.catalog_read_model_refresh_state s where s.singleton;
  if v_completed_version is distinct from 2476 then
    raise exception 'Completed version changed from baseline 2476 to %; inspect before catch-up',
      v_completed_version;
  end if;

  select c.reltuples into v_estimated_rows
  from pg_class c where c.oid = 'public.catalog_items_read'::regclass;
  select count(*) into v_live_rows from public.catalog_items_read;

  if v_live_rows = 0 or v_estimated_rows < v_live_rows * 0.85
      or v_estimated_rows > v_live_rows * 1.15 then
    raise exception 'Run and verify fresh ANALYZE: planner rows %, live rows %',
      v_estimated_rows, v_live_rows;
  end if;
end;
$$;

select public.process_catalog_items_read_refresh() as catch_up_result;

commit;
