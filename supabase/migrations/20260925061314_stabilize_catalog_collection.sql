begin;

alter table public.catalog_sync_cycles
  add column if not exists reconciled_missing boolean not null default false;

comment on column public.catalog_sync_cycles.reconciled_missing is
  'True only when every completed task reached 100% and missing-product counters were reconciled.';

update public.catalog_sync_cycles cycle
set reconciled_missing = true
where cycle.status = 'success'
  and exists (select 1 from public.catalog_collection_tasks task where task.cycle_id = cycle.id)
  and not exists (
    select 1 from public.catalog_collection_tasks task
    where task.cycle_id = cycle.id
      and (task.status <> 'completed' or task.expected_total is null or task.collected_count < task.expected_total)
  );

create or replace function public.finish_sync_run_with_policy(
  p_run_id uuid,
  p_status public.sync_run_status,
  p_pages_count integer,
  p_products_count integer,
  p_error text,
  p_reconcile_missing boolean
) returns void language plpgsql security definer set search_path = public as $$
declare v_target_id uuid; v_run_started_at timestamptz;
begin
  select target_id, started_at into v_target_id, v_run_started_at
  from public.sync_runs where id = p_run_id;
  if v_target_id is null then raise exception 'Sync run does not exist'; end if;

  if p_status = 'success' and p_products_count = 0 then
    p_status := 'failed';
    p_error := coalesce(p_error, 'An empty collection cannot be marked successful.');
    p_reconcile_missing := false;
  end if;

  update public.sync_runs set status = p_status, finished_at = now(), pages_count = p_pages_count,
    products_count = p_products_count, error = p_error where id = p_run_id;

  if p_status = 'success' then
    if p_reconcile_missing then
      update public.sync_target_products set
        missing_successful_runs = case when last_seen_run_id = p_run_id then 0 else missing_successful_runs + 1 end,
        active = case when last_seen_run_id = p_run_id then true else missing_successful_runs + 1 < 2 end
      where target_id = v_target_id;

      update public.products p set active = exists (
        select 1 from public.sync_target_products stp where stp.product_id = p.id and stp.active
      ) where exists (
        select 1 from public.sync_target_products x where x.product_id = p.id and x.target_id = v_target_id
      );
    end if;

    update public.sync_targets set last_success_at = now(), last_error = null,
      requested_at = case when requested_at is null or requested_at <= v_run_started_at then null else requested_at end,
      updated_at = now()
    where id = v_target_id;
  else
    update public.sync_targets set last_error = p_error, updated_at = now() where id = v_target_id;
  end if;
end $$;

-- Preserve the existing public signature for legacy callers. They retain the
-- historical behavior in which a successful run performs reconciliation.
create or replace function public.finish_sync_run(
  p_run_id uuid,
  p_status public.sync_run_status,
  p_pages_count integer,
  p_products_count integer,
  p_error text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.finish_sync_run_with_policy(
    p_run_id, p_status, p_pages_count, p_products_count, p_error, true
  );
end $$;

create or replace function public.finish_catalog_collection_task(
  p_task_id uuid, p_lease_token uuid, p_complete boolean, p_expected_total integer,
  p_collected_count integer, p_pages_count integer, p_error text default null,
  p_rate_limited boolean default false, p_retry_after_seconds integer default null
) returns public.catalog_task_status language plpgsql security definer set search_path = public as $$
declare v_task public.catalog_collection_tasks%rowtype; v_cycle public.catalog_sync_cycles%rowtype;
declare v_status public.catalog_task_status; v_delay interval; v_unique_count integer; v_pages integer;
declare v_reconcile_missing boolean;
begin
  select * into v_task from public.catalog_collection_tasks
  where id = p_task_id and status = 'processing' and lease_token = p_lease_token and lease_until >= now() for update;
  if not found then raise exception 'Catalog task lease is missing or expired'; end if;
  select * into v_cycle from public.catalog_sync_cycles where id = v_task.cycle_id for update;

  if p_complete and p_expected_total is not null and p_expected_total > 0
      and p_collected_count >= ceil(p_expected_total * 0.99) and p_error is null then
    v_status := 'completed';
  elsif v_task.attempts >= 5 then
    v_status := 'blocked';
  else
    v_status := 'retryable';
  end if;

  v_delay := case v_task.attempts when 1 then interval '5 minutes' when 2 then interval '15 minutes' else interval '60 minutes' end;
  update public.catalog_collection_tasks
  set status = v_status, expected_total = p_expected_total,
      collected_count = greatest(collected_count, p_collected_count), pages_count = greatest(pages_count, p_pages_count),
      next_attempt_at = case when v_status = 'retryable' then now() + v_delay else next_attempt_at end,
      lease_token = null, lease_until = null, last_error = p_error,
      completed_at = case when v_status = 'completed' then now() else null end,
      updated_at = now()
  where id = p_task_id;

  if p_rate_limited then
    insert into public.catalog_source_pauses(source_id, paused_until, reason)
    values (v_cycle.source_id, now() + greatest(coalesce(p_retry_after_seconds, 0), 3600) * interval '1 second', coalesce(p_error, 'ABOUT YOU rate limited'))
    on conflict (source_id) do update
      set paused_until = greatest(catalog_source_pauses.paused_until, excluded.paused_until),
          reason = excluded.reason, updated_at = now();
  end if;

  if not exists (
    select 1 from public.catalog_collection_tasks
    where cycle_id = v_cycle.id and status not in ('completed', 'blocked')
  ) then
    select count(*) into v_unique_count
    from public.sync_target_products where target_id = v_cycle.target_id and last_seen_run_id = v_cycle.sync_run_id;
    select coalesce(sum(pages_count), 0) into v_pages
    from public.catalog_collection_tasks where cycle_id = v_cycle.id;
    select coalesce(bool_and(expected_total is not null and collected_count >= expected_total), false)
      into v_reconcile_missing
    from public.catalog_collection_tasks where cycle_id = v_cycle.id and status = 'completed';

    if exists (
      select 1 from public.catalog_collection_tasks where cycle_id = v_cycle.id and status = 'blocked'
    ) then
      update public.catalog_sync_cycles
      set status = 'partial', finished_at = now(), error = 'One or more catalog manifest parts were blocked.',
          reconciled_missing = false
      where id = v_cycle.id;
      perform public.finish_sync_run_with_policy(
        v_cycle.sync_run_id, 'partial', v_pages, v_unique_count,
        'One or more catalog manifest parts were blocked.', false
      );
    else
      update public.catalog_sync_cycles
      set status = 'success', finished_at = now(), error = null,
          reconciled_missing = v_reconcile_missing
      where id = v_cycle.id;
      perform public.finish_sync_run_with_policy(
        v_cycle.sync_run_id, 'success', v_pages, v_unique_count, null, v_reconcile_missing
      );
    end if;
  end if;
  return v_status;
end $$;

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
        or (latest.status = 'success' and latest.finished_at <= now() - interval '24 hours')
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

revoke all on function public.finish_sync_run_with_policy(uuid, public.sync_run_status, integer, integer, text, boolean)
  from public, anon, authenticated;
revoke all on function public.finish_sync_run(uuid, public.sync_run_status, integer, integer, text)
  from public, anon, authenticated;
revoke all on function public.finish_catalog_collection_task(uuid, uuid, boolean, integer, integer, integer, text, boolean, integer)
  from public, anon, authenticated;
revoke all on function public.claim_catalog_collection_task(text)
  from public, anon, authenticated;

grant execute on function public.finish_sync_run_with_policy(uuid, public.sync_run_status, integer, integer, text, boolean)
  to service_role;
grant execute on function public.finish_sync_run(uuid, public.sync_run_status, integer, integer, text)
  to service_role;
grant execute on function public.finish_catalog_collection_task(uuid, uuid, boolean, integer, integer, integer, text, boolean, integer)
  to service_role;
grant execute on function public.claim_catalog_collection_task(text)
  to service_role;

notify pgrst, 'reload schema';

commit;
