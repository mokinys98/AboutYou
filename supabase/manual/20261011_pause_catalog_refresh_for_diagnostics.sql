-- Run in VPS Supabase SQL Editor to pause the 5-minute refresh for diagnostics.
-- An already-running refresh may finish after this transaction commits.
-- Uses the pg_cron API because SQL Editor's postgres role cannot UPDATE cron.job.
begin;

do $$
declare
  v_jobid bigint;
  v_active boolean;
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  select j.jobid, j.active
  into strict v_jobid, v_active
  from cron.job j
  where j.jobname = 'catalog-read-model-refresh'
    and j.schedule = '*/5 * * * *'
    and j.command ilike '%process_catalog_items_read_refresh()%'
    and j.username = current_user;

  if not v_active then
    raise exception 'Catalog refresh job % is already inactive; inspect cron.job', v_jobid;
  end if;

  perform cron.alter_job(v_jobid, active => false);

  if not exists (
    select 1 from cron.job j where j.jobid = v_jobid and not j.active
  ) then
    raise exception 'Catalog refresh job % did not become inactive', v_jobid;
  end if;
end;
$$;

commit;
