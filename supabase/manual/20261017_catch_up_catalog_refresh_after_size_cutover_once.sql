-- One controlled catch-up after the optimized size-facet cutover.
-- Run only after verify_catalog_size_facets_optimized_cutover_read_only.sql
-- succeeds and while the 5-minute cron remains paused. This does not resume
-- cron. Run once; if SQL Editor times out, inspect the separate verification
-- query before considering another call.
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

  if exists (
    select 1
    from cron.job_run_details r
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
    where c.oid = 'public.catalog_size_facets_read'::regclass
      and c.relkind = 'm'
      and c.relispopulated
      and pg_get_userbyid(c.relowner) = current_user
  ) or not exists (
    select 1 from pg_class c
    where c.oid = 'public.catalog_size_facets_read_backup_20261017'::regclass
      and c.relkind = 'm'
      and c.relispopulated
      and pg_get_userbyid(c.relowner) = current_user
  ) then
    raise exception 'Expected populated production and rollback size MVs owned by postgres';
  end if;

  if has_table_privilege('anon', 'public.catalog_size_facets_read_backup_20261017', 'SELECT')
     or has_table_privilege('authenticated', 'public.catalog_size_facets_read_backup_20261017', 'SELECT')
     or has_table_privilege('service_role', 'public.catalog_size_facets_read_backup_20261017', 'SELECT') then
    raise exception 'Rollback backup is unexpectedly readable by an API role';
  end if;

  if not exists (
    select 1 from pg_depend d
    join pg_rewrite rw on rw.oid = d.objid
    where rw.ev_class = 'public.catalog_size_facets_read_effective'::regclass
      and d.refobjid = 'public.catalog_size_facets_read'::regclass
  ) or exists (
    select 1 from pg_depend d
    join pg_rewrite rw on rw.oid = d.objid
    where rw.ev_class = 'public.catalog_size_facets_read_effective'::regclass
      and d.refobjid = 'public.catalog_size_facets_read_backup_20261017'::regclass
  ) then
    raise exception 'Effective size view is not attached exclusively to the optimized production MV';
  end if;

  if (select count(*) from pg_index i
      join pg_class ic on ic.oid = i.indexrelid
      where i.indrelid = 'public.catalog_size_facets_read'::regclass
        and ic.relname in (
          'catalog_size_facets_read_optimized_stage_unique_idx',
          'catalog_size_facets_read_optimized_stage_domain_idx',
          'catalog_size_facets_read_optimized_stage_token_idx'
        ) and i.indisvalid and i.indisready) <> 3 then
    raise exception 'Expected all three valid and ready optimized production indexes';
  end if;

  if md5(pg_get_viewdef('public.catalog_size_facets_read_effective'::regclass, true))
      <> '88c25cab7939592911a1f1a045b772e9' then
    raise exception 'Effective size view definition changed; inspect before catch-up';
  end if;

  select s.completed_version into v_completed_version
  from public.catalog_read_model_refresh_state s where s.singleton;
  if v_completed_version is distinct from 2707 then
    raise exception 'Completed version changed from baseline 2707 to %; inspect before catch-up',
      v_completed_version;
  end if;

  select c.reltuples into v_estimated_rows
  from pg_class c where c.oid = 'public.catalog_items_read'::regclass;
  select count(*) into v_live_rows from public.catalog_items_read;

  if v_live_rows = 0 or v_estimated_rows < v_live_rows * 0.85
      or v_estimated_rows > v_live_rows * 1.15 then
    raise exception 'Planner row estimate is stale: planner rows %, live rows %; analyze first',
      v_estimated_rows, v_live_rows;
  end if;
end;
$$;

select public.process_catalog_items_read_refresh() as catch_up_result;

commit;
