-- Add production-equivalent indexes to the isolated optimized stage.
-- This does not switch consumers or change cron. First run
-- 20261017_refresh_and_verify_optimized_catalog_size_facets_stage_once.sql
-- and confirm differing_rows=0. Run this only once in VPS SQL Editor.
begin;
set local statement_timeout = '90s';
set local lock_timeout = '3s';

do $$
declare
  v_jobs integer;
  v_paused boolean;
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  select count(*), coalesce(bool_and(not j.active), false)
  into v_jobs, v_paused
  from cron.job j
  where j.jobname = 'catalog-read-model-refresh'
    and j.schedule = '*/5 * * * *'
    and j.command ilike '%process_catalog_items_read_refresh()%';

  if v_jobs <> 1 or not v_paused then
    raise exception 'Expected exactly one paused catalog refresh job; found %, all_paused=%',
      v_jobs, v_paused;
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
        'public.catalog_effective_size_membership_read'::regclass,
        'public.catalog_size_facets_read_optimized_stage'::regclass
      ) and l.mode in ('ExclusiveLock', 'AccessExclusiveLock') and l.granted)
  ) then
    raise exception 'A catalog refresh or stage lock is still held';
  end if;

  if not exists (
    select 1 from pg_class c
    where c.oid = 'public.catalog_size_facets_read_optimized_stage'::regclass
      and c.relkind = 'm'
      and c.relispopulated
      and pg_get_userbyid(c.relowner) = current_user
  ) then
    raise exception 'Expected populated optimized stage owned by postgres';
  end if;

  if exists (
    select 1
    from public.catalog_size_facets_read_optimized_stage
    group by product_id, token
    having count(*) > 1
  ) then
    raise exception 'Stage has duplicate (product_id, token) keys; inspect before indexing';
  end if;

  if exists (
    select 1 from pg_class
    where relname in (
      'catalog_size_facets_read_optimized_stage_unique_idx',
      'catalog_size_facets_read_optimized_stage_domain_idx',
      'catalog_size_facets_read_optimized_stage_token_idx'
    ) and relnamespace = 'public'::regnamespace
  ) then
    raise exception 'One or more optimized-stage index names already exist; inspect before retrying';
  end if;
end;
$$;

create unique index catalog_size_facets_read_optimized_stage_unique_idx
  on public.catalog_size_facets_read_optimized_stage (product_id, token);

create index catalog_size_facets_read_optimized_stage_domain_idx
  on public.catalog_size_facets_read_optimized_stage
  (domain_key, sort_order, display_label, product_id);

create index catalog_size_facets_read_optimized_stage_token_idx
  on public.catalog_size_facets_read_optimized_stage (token, product_id);

commit;
