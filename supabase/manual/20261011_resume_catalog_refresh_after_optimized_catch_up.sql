-- VPS SQL Editor: resume the 5-minute catalog refresh after the successful
-- 19:06–19:10 UTC catch-up and subsequent autovacuum on catalog_items_read.
-- This file is specific to the 2026-10-11 incident; run it only once.
begin;
set local statement_timeout = '5s';
set local lock_timeout = '3s';

do $$
declare
  v_jobid bigint;
  v_active boolean;
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  select j.jobid, j.active into strict v_jobid, v_active
  from cron.job j
  where j.jobname = 'catalog-read-model-refresh'
    and j.schedule = '*/5 * * * *'
    and j.command ilike '%process_catalog_items_read_refresh()%'
    and j.username = current_user;

  if v_active then
    raise exception 'Catalog refresh job % is already active', v_jobid;
  end if;

  if not exists (
    select 1 from public.catalog_read_model_refresh_state s
    where s.singleton
      and s.completed_version >= 2707
      and s.last_status in ('refreshed', 'pending', 'clean')
      and s.last_duration_ms < 300000
      and s.refresh_completed_at > timestamptz '2026-10-11 19:10:49+00'
      and s.last_error is null
  ) then
    raise exception 'Expected the confirmed sub-5-minute successful catch-up';
  end if;

  if exists (
    select 1 from pg_locks l
    where l.locktype = 'advisory'
      and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted
  ) then
    raise exception 'A catalog refresh is still running';
  end if;

  if not exists (
    select 1
    from pg_stat_all_tables st
    cross join public.catalog_read_model_refresh_state s
    where st.relid = 'public.catalog_items_read'::regclass
      and s.singleton
      and st.last_autovacuum > s.refresh_completed_at
      and st.n_dead_tup <= 5000
  ) then
    raise exception 'Catalog items autovacuum has not cleared post-refresh dead tuples';
  end if;

  perform cron.alter_job(v_jobid, active => true);

  if not exists (select 1 from cron.job j where j.jobid = v_jobid and j.active) then
    raise exception 'Catalog refresh job % did not become active', v_jobid;
  end if;
end;
$$;

commit;
