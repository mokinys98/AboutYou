-- Run once in VPS Supabase SQL Editor only after
-- 20261014195500_stage_optimized_catalog_size_facets_read.sql succeeds.
-- The matching source SELECT took 19.656 s through the authorized direct
-- read-only tunnel. REFRESH also writes the stage heap, so its total duration
-- is not yet measured and SQL Editor may hit its upstream timeout. If it
-- reports an upstream timeout, run the separate read-only stage verification
-- before retrying; do not assume the refresh rolled back.
begin;
set local statement_timeout = '45s';
set local lock_timeout = '3s';

do $$
declare
  v_jobs integer;
  v_all_paused boolean;
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  select count(*), coalesce(bool_and(not j.active), false)
  into v_jobs, v_all_paused
  from cron.job j
  where j.jobname = 'catalog-read-model-refresh'
    and j.schedule = '*/5 * * * *'
    and j.command ilike '%process_catalog_items_read_refresh()%';

  if v_jobs <> 1 or not v_all_paused then
    raise exception 'Expected exactly one paused catalog refresh job; found %, all_paused=%',
      v_jobs, v_all_paused;
  end if;

  if exists (
    select 1 from cron.job_run_details r
    join cron.job j on j.jobid = r.jobid
    where j.jobname = 'catalog-read-model-refresh'
      and r.status = 'running'
      and r.end_time is null
  ) then
    raise exception 'A catalog refresh cron run is still active';
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

  if not exists (
    select 1 from pg_class c
    where c.oid = 'public.catalog_size_facets_read_optimized_stage'::regclass
      and c.relkind = 'm'
      and not c.relispopulated
      and pg_get_userbyid(c.relowner) = current_user
  ) then
    raise exception 'Expected one unpopulated stage materialized view owned by postgres';
  end if;
end;
$$;

refresh materialized view public.catalog_size_facets_read_optimized_stage;

commit;
