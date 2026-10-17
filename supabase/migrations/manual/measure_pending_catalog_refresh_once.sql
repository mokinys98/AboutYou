-- Manual SQL Editor measurement only, after 20261018100000 is installed.
-- Kept in migrations/manual so automated top-level migration runners do not
-- execute a heavy refresh as part of a future schema deployment.
-- Runs one pending refresh while the scheduled five-minute job remains paused.
-- The 12-minute timeout applies only to this SQL Editor transaction; it does
-- not change the cron job, its five-minute timeout, or any cache TTL.
begin;
set local statement_timeout = '12min';
set local lock_timeout = '3s';

do $$
declare
  v_requested bigint;
  v_completed bigint;
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;
  if to_regclass('public.catalog_refresh_runs') is null
      or to_regclass('public.catalog_refresh_phases') is null
      or position('catalog_refresh_runs' in
        pg_get_functiondef('public.process_catalog_items_read_refresh()'::regprocedure)) = 0 then
    raise exception 'Persistent catalog refresh metrics are not installed';
  end if;
  if not (select count(*) = 1 and
        coalesce(bool_and(not active and schedule = '*/5 * * * *'
          and command ilike '%process_catalog_items_read_refresh()%'), false)
      from cron.job where jobname = 'catalog-read-model-refresh') then
    raise exception 'Expected exactly one paused five-minute catalog refresh job';
  end if;
  if exists (
    select 1 from cron.job_run_details r
    join cron.job j on j.jobid = r.jobid
    where j.jobname = 'catalog-read-model-refresh'
      and r.status = 'running' and r.end_time is null
  ) or exists (
    select 1 from pg_locks l
    where l.locktype = 'advisory' and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted
  ) then
    raise exception 'A catalog refresh may already be active';
  end if;
  if not exists (
    select 1 from pg_class c
    where c.oid = 'public.catalog_size_facets_read'::regclass
      and c.relkind = 'm' and c.relispopulated
  ) or not exists (
    select 1 from pg_depend d
    join pg_rewrite rw on rw.oid = d.objid
    where rw.ev_class = 'public.catalog_size_facets_read_effective'::regclass
      and d.refobjid = 'public.catalog_size_facets_read'::regclass
  ) then
    raise exception 'Optimized production size facets cutover is not ready';
  end if;
  select requested_version, completed_version
    into v_requested, v_completed
  from public.catalog_read_model_refresh_state where singleton;
  if v_requested is null or v_completed is null or v_requested <= v_completed then
    raise exception 'No pending catalog refresh (requested %, completed %)',
      v_requested, v_completed;
  end if;
end;
$$;

select public.process_catalog_items_read_refresh() as measurement_result;

commit;
