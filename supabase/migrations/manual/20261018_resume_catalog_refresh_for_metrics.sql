-- Run once in the VPS Supabase SQL Editor after the measured refresh and
-- its post-refresh autovacuum have been verified. This only reactivates the
-- existing five-minute cron job; it does not change its schedule, command,
-- timeout, or cache settings.
begin;
set local statement_timeout = '5s';
set local lock_timeout = '3s';

do $$
declare
  v_jobid bigint;
  v_active boolean;
  v_run_id bigint;
  v_run_outcome text;
  v_run_duration_ms bigint;
  v_run_target_version bigint;
  v_requested_version bigint;
  v_completed_version bigint;
  v_refresh_completed_at timestamptz;
  v_last_error text;
  v_phase_count bigint;
  v_success_count bigint;
  v_phase_order text[];
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  select j.jobid, j.active into strict v_jobid, v_active
  from cron.job j
  where j.jobname = 'catalog-read-model-refresh'
    and j.username = current_user
    and j.database = current_database()
    and j.schedule = '*/5 * * * *'
    and j.command ilike '%set statement_timeout = ''5min''%'
    and j.command ilike '%set lock_timeout = ''3s''%'
    and j.command ilike '%process_catalog_items_read_refresh()%';
  if v_active then
    raise exception 'Catalog refresh job % is already active', v_jobid;
  end if;

  select r.run_id, r.outcome, r.duration_ms, r.target_version
    into strict v_run_id, v_run_outcome, v_run_duration_ms, v_run_target_version
  from public.catalog_refresh_runs r
  order by r.run_id desc limit 1;
  if v_run_outcome is distinct from 'refreshed'
      or v_run_duration_ms >= 300000 then
    raise exception 'Latest measured refresh must have succeeded in under five minutes';
  end if;

  select s.requested_version, s.completed_version, s.refresh_completed_at,
      s.last_error
    into strict v_requested_version, v_completed_version,
      v_refresh_completed_at, v_last_error
  from public.catalog_read_model_refresh_state s
  where s.singleton;
  if v_requested_version is distinct from v_completed_version
      or v_completed_version is distinct from v_run_target_version
      or v_last_error is not null then
    raise exception 'Catalog refresh state is not caught up with the measured run';
  end if;

  select count(*), count(*) filter (where p.outcome = 'success'),
      array_agg(p.phase order by p.phase_id)
    into v_phase_count, v_success_count, v_phase_order
  from public.catalog_refresh_phases p where p.run_id = v_run_id;
  if v_phase_count <> 9 or v_success_count <> 9 or
      v_phase_order is distinct from array[
        'catalog_items_read', 'catalog_items_read_analyze',
        'catalog_item_facet_values_read', 'catalog_size_facets_read',
        'catalog_size_facets_read_analyze', 'effective_size_membership',
        'static_size_facets_cache', 'facet_cache_delete',
        'root_facet_cache_prewarm'
      ]::text[] then
    raise exception 'Latest measured refresh is missing successful phases';
  end if;

  if not exists (
    select 1 from pg_stat_all_tables st
    where st.relid = 'public.catalog_items_read'::regclass
      and st.last_autovacuum > v_refresh_completed_at
      and st.n_dead_tup <= 5000
  ) then
    raise exception 'Post-refresh autovacuum has not cleared catalog_items_read';
  end if;
  if not exists (
    select 1 from pg_class c
    where c.oid = 'public.catalog_size_facets_read'::regclass
      and c.relkind = 'm' and c.relispopulated
  ) or not exists (
    select 1 from pg_depend d join pg_rewrite rw on rw.oid = d.objid
    where rw.ev_class = 'public.catalog_size_facets_read_effective'::regclass
      and d.refobjid = 'public.catalog_size_facets_read'::regclass
  ) then
    raise exception 'Optimized production size facets cutover is not ready';
  end if;
  if exists (
    select 1 from cron.job_run_details r
    where r.jobid = v_jobid and r.status = 'running' and r.end_time is null
  ) or exists (
    select 1 from pg_locks l
    where l.locktype = 'advisory' and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted
  ) then
    raise exception 'A catalog refresh may already be active';
  end if;

  perform cron.alter_job(v_jobid, active => true);
  -- Recheck the complete job identity and command after cron.alter_job.
  -- postgres can execute cron.alter_job but has no UPDATE on cron.job, so a
  -- SELECT FOR UPDATE precheck is unavailable. A changed row here aborts the
  -- transaction, rolling back the activation.
  if not exists (
    select 1 from cron.job j
    where j.jobid = v_jobid and j.active
      and j.jobname = 'catalog-read-model-refresh'
      and j.username = current_user
      and j.database = current_database()
      and j.schedule = '*/5 * * * *'
      and j.command ilike '%set statement_timeout = ''5min''%'
      and j.command ilike '%set lock_timeout = ''3s''%'
      and j.command ilike '%process_catalog_items_read_refresh()%'
  ) then
    raise exception 'Catalog refresh job % changed or did not become active', v_jobid;
  end if;
end;
$$;

commit;
