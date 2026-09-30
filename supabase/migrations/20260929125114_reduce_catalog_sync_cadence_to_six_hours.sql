begin;

-- Refresh successful catalog targets every six hours so prices and catalog
-- availability do not remain stale for a full day. Manual requests still run
-- immediately, while partial and failed cycles keep their existing six-hour
-- cooldown.
create or replace function public.claim_catalog_collection_task(p_target_label text default '')
returns table(
  task_id uuid, lease_token uuid, cycle_id uuid, sync_run_id uuid,
  target_id uuid, source_id uuid, target_label text, target_kind public.sync_target_kind,
  part_key text, part_url text, attempt smallint, lease_until timestamptz
) language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_task public.catalog_collection_tasks%rowtype;
declare v_token uuid := gen_random_uuid();
begin
  perform pg_advisory_xact_lock(hashtextextended('catalog-collection-cycle-claim', 0));

  insert into public.catalog_target_parts(target_id, part_key, url)
  select st.id, 'root', st.url from public.sync_targets st where st.enabled
  on conflict (target_id, part_key) do nothing;

  update public.catalog_collection_tasks
  set status = 'retryable', next_attempt_at = now(), lease_token = null, lease_until = null,
      last_error = coalesce(last_error, 'Worker lease expired.'), updated_at = now()
  where status = 'processing' and lease_until < now();

  with candidates as materialized (
    select st.id as target_id, st.source_id, st.requested_at
    from public.sync_targets st
    left join lateral (
      select c.status, c.started_at, c.finished_at
      from public.catalog_sync_cycles c
      where c.target_id = st.id
      order by c.started_at desc
      limit 1
    ) latest on true
    where st.enabled and (p_target_label = '' or st.label = p_target_label)
      and not exists (
        select 1 from public.catalog_sync_cycles running
        where running.target_id = st.id and running.status = 'running'
      )
      and (
        latest.started_at is null
        or (st.requested_at is not null and st.requested_at > latest.started_at)
        or (latest.status = 'success' and latest.finished_at <= now() - interval '6 hours')
        or (latest.status in ('partial', 'failed') and latest.finished_at <= now() - interval '6 hours')
      )
  ), new_runs as (
    insert into public.sync_runs(target_id, status)
    select candidate.target_id, 'running' from candidates candidate
    returning id, target_id
  ), new_cycles as (
    insert into public.catalog_sync_cycles(target_id, source_id, sync_run_id)
    select run.target_id, candidate.source_id, run.id
    from new_runs run join candidates candidate on candidate.target_id = run.target_id
    returning id, target_id
  ), consumed_requests as (
    update public.sync_targets st
    set requested_at = null, last_started_at = now(), updated_at = now()
    from candidates candidate join new_cycles cycle on cycle.target_id = candidate.target_id
    where st.id = candidate.target_id and st.requested_at is not distinct from candidate.requested_at
    returning st.id
  )
  insert into public.catalog_collection_tasks(cycle_id, part_id)
  select cycle.id, part.id
  from new_cycles cycle
  join public.catalog_target_parts part on part.target_id = cycle.target_id and part.enabled;

  select task.* into v_task
  from public.catalog_collection_tasks task
  join public.catalog_sync_cycles cycle on cycle.id = task.cycle_id and cycle.status = 'running'
  join public.catalog_target_parts part on part.id = task.part_id and part.enabled
  join public.sync_targets target on target.id = cycle.target_id and target.enabled
  left join public.catalog_source_pauses pause on pause.source_id = cycle.source_id
  where task.status in ('pending', 'retryable') and task.next_attempt_at <= now()
    and (p_target_label = '' or target.label = p_target_label)
    and (pause.paused_until is null or pause.paused_until <= now())
  order by cycle.started_at asc, target.priority asc, part.priority asc, task.created_at asc
  for update of task skip locked limit 1;
  if not found then return; end if;

  update public.catalog_collection_tasks
  set status = 'processing', attempts = attempts + 1, lease_token = v_token,
      lease_until = now() + interval '3 minutes', updated_at = now()
  where id = v_task.id;

  return query
  select task.id, task.lease_token, cycle.id, cycle.sync_run_id, target.id, target.source_id,
         target.label, target.kind, part.part_key, part.url, task.attempts, task.lease_until
  from public.catalog_collection_tasks task
  join public.catalog_sync_cycles cycle on cycle.id = task.cycle_id
  join public.sync_targets target on target.id = cycle.target_id
  join public.catalog_target_parts part on part.id = task.part_id
  where task.id = v_task.id;
end $$;

revoke all on function public.claim_catalog_collection_task(text)
  from public, anon, authenticated;
grant execute on function public.claim_catalog_collection_task(text)
  to service_role;

notify pgrst, 'reload schema';

commit;
