-- RETURNS TABLE output names (target_id, lease_until, etc.) are PL/pgSQL variables.
-- Prefer SQL columns in this function to avoid SQLSTATE 42702 during a claim.
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
  select id, 'root', url from public.sync_targets where enabled
  on conflict (target_id, part_key) do nothing;

  update public.catalog_collection_tasks
  set status = 'retryable', next_attempt_at = now(), lease_token = null, lease_until = null,
      last_error = coalesce(last_error, 'Worker lease expired.'), updated_at = now()
  where status = 'processing' and lease_until < now();

  with new_runs as (
    insert into public.sync_runs(target_id, status)
    select t.id, 'running'
    from public.sync_targets t
    where t.enabled and (p_target_label = '' or t.label = p_target_label)
      and not exists (select 1 from public.catalog_sync_cycles c where c.target_id = t.id and c.status = 'running')
      and not exists (select 1 from public.catalog_sync_cycles c where c.target_id = t.id and c.started_at > now() - interval '24 hours')
    returning id, target_id
  ), new_cycles as (
    insert into public.catalog_sync_cycles(target_id, source_id, sync_run_id)
    select r.target_id, t.source_id, r.id from new_runs r join public.sync_targets t on t.id = r.target_id
    returning id, target_id
  )
  insert into public.catalog_collection_tasks(cycle_id, part_id)
  select c.id, p.id from new_cycles c join public.catalog_target_parts p on p.target_id = c.target_id and p.enabled;

  select q.* into v_task
  from public.catalog_collection_tasks q
  join public.catalog_sync_cycles c on c.id = q.cycle_id and c.status = 'running'
  join public.catalog_target_parts p on p.id = q.part_id and p.enabled
  join public.sync_targets t on t.id = c.target_id and t.enabled
  left join public.catalog_source_pauses pause on pause.source_id = c.source_id
  where q.status in ('pending', 'retryable') and q.next_attempt_at <= now()
    and (p_target_label = '' or t.label = p_target_label)
    and (pause.paused_until is null or pause.paused_until <= now())
  order by c.started_at asc, t.priority asc, p.priority asc, q.created_at asc
  for update of q skip locked limit 1;
  if not found then return; end if;

  update public.catalog_collection_tasks
  set status = 'processing', attempts = attempts + 1, lease_token = v_token,
      lease_until = now() + interval '3 minutes', updated_at = now()
  where id = v_task.id;

  return query
  select q.id, q.lease_token, c.id, c.sync_run_id, t.id, t.source_id, t.label, t.kind,
         p.part_key, p.url, q.attempts, q.lease_until
  from public.catalog_collection_tasks q
  join public.catalog_sync_cycles c on c.id = q.cycle_id
  join public.sync_targets t on t.id = c.target_id
  join public.catalog_target_parts p on p.id = q.part_id
  where q.id = v_task.id;
end $$;

revoke all on function public.claim_catalog_collection_task(text) from public, anon, authenticated;
grant execute on function public.claim_catalog_collection_task(text) to service_role;
