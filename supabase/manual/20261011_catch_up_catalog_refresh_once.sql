-- One controlled catch-up run in VPS Supabase SQL Editor, after ANALYZE and
-- while the 5-minute cron job is still paused. Run this file only once;
-- inspect its JSON result and the separate read-only verification before retry.
-- SQL Editor may report Success even if the JSON status is failed/busy/clean;
-- only status=refreshed confirms this call completed a refresh.
begin;
set local statement_timeout = '12min';
set local lock_timeout = '3s';

do $$
declare
  v_estimated_rows float8;
  v_live_rows bigint;
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

  select c.reltuples into v_estimated_rows
  from pg_class c where c.oid = 'public.catalog_items_read'::regclass;
  select count(*) into v_live_rows from public.catalog_items_read;

  if v_live_rows = 0 or v_estimated_rows < v_live_rows * 0.5
      or v_estimated_rows > v_live_rows * 2.0 then
    raise exception 'Run and verify ANALYZE first: planner rows %, live rows %',
      v_estimated_rows, v_live_rows;
  end if;
end;
$$;

select public.process_catalog_items_read_refresh() as catch_up_result;

commit;
