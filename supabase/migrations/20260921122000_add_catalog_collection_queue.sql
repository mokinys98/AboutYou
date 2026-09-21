-- A catalog cycle is intentionally separate from a GitHub Actions invocation.
-- A run is reconciled only after every manifest part has been confirmed.
create type public.catalog_cycle_status as enum ('running', 'success', 'partial', 'failed');
create type public.catalog_task_status as enum ('pending', 'processing', 'retryable', 'completed', 'blocked');

create table public.catalog_target_parts (
  id uuid primary key default gen_random_uuid(),
  target_id uuid not null references public.sync_targets(id) on delete cascade,
  part_key text not null,
  url text not null check (url ~ '^https:\/\/([a-z0-9-]+\.)?aboutyou\.lt\/'),
  enabled boolean not null default true,
  priority integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (target_id, part_key)
);

-- Seed each existing target with one manifest part. Subsequent migrations may add
-- smaller category parts without changing the owning target or its memberships.
insert into public.catalog_target_parts(target_id, part_key, url)
select id, 'root', url from public.sync_targets
on conflict (target_id, part_key) do nothing;

create table public.catalog_sync_cycles (
  id uuid primary key default gen_random_uuid(),
  target_id uuid not null references public.sync_targets(id) on delete cascade,
  source_id uuid not null references public.sources(id),
  sync_run_id uuid not null unique references public.sync_runs(id) on delete cascade,
  status public.catalog_cycle_status not null default 'running',
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  error text
);
create unique index catalog_sync_cycles_one_running_target_idx
  on public.catalog_sync_cycles(target_id) where status = 'running';

create table public.catalog_collection_tasks (
  id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null references public.catalog_sync_cycles(id) on delete cascade,
  part_id uuid not null references public.catalog_target_parts(id) on delete restrict,
  status public.catalog_task_status not null default 'pending',
  attempts smallint not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  expected_total integer,
  collected_count integer not null default 0,
  pages_count integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (cycle_id, part_id),
  check ((status = 'processing') = (lease_token is not null and lease_until is not null))
);
create index catalog_collection_tasks_claim_idx on public.catalog_collection_tasks(status, next_attempt_at, created_at);

create table public.catalog_collection_pages (
  task_id uuid not null references public.catalog_collection_tasks(id) on delete cascade,
  page_number integer not null check (page_number > 0),
  page_key text not null,
  product_count integer not null check (product_count >= 0),
  created_at timestamptz not null default now(),
  primary key (task_id, page_key)
);

create table public.catalog_source_pauses (
  source_id uuid primary key references public.sources(id) on delete cascade,
  paused_until timestamptz not null,
  reason text not null,
  updated_at timestamptz not null default now()
);

alter table public.catalog_target_parts enable row level security;
alter table public.catalog_sync_cycles enable row level security;
alter table public.catalog_collection_tasks enable row level security;
alter table public.catalog_collection_pages enable row level security;
alter table public.catalog_source_pauses enable row level security;

-- Create at most one cycle per target per 24h, initialise its immutable part set,
-- recover expired leases, then atomically lease the oldest runnable task.
create or replace function public.claim_catalog_collection_task(p_target_label text default '')
returns table(
  task_id uuid, lease_token uuid, cycle_id uuid, sync_run_id uuid,
  target_id uuid, source_id uuid, target_label text, target_kind public.sync_target_kind,
  part_key text, part_url text, attempt smallint, lease_until timestamptz
) language plpgsql security definer set search_path = public as $$
declare v_task public.catalog_collection_tasks%rowtype;
declare v_token uuid := gen_random_uuid();
begin
  -- The short transaction-wide lock prevents two GitHub dispatches from creating
  -- competing cycles for the same target before the partial unique index applies.
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
      and (t.last_success_at is null or t.last_success_at <= now() - interval '24 hours')
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

create or replace function public.renew_catalog_collection_lease(p_task_id uuid, p_lease_token uuid)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_until timestamptz;
begin
  update public.catalog_collection_tasks
  set lease_until = now() + interval '3 minutes', updated_at = now()
  where id = p_task_id and status = 'processing' and lease_token = p_lease_token and lease_until >= now()
  returning lease_until into v_until;
  if v_until is null then raise exception 'Catalog task lease is missing or expired'; end if;
  return v_until;
end $$;

-- The page marker gates the underlying catalog write. A retry of an acknowledged
-- page returns zero and cannot create extra price observations.
create or replace function public.record_catalog_collection_page(
  p_task_id uuid, p_lease_token uuid, p_page_number integer, p_page_key text, p_products jsonb
) returns integer language plpgsql security definer set search_path = public as $$
declare v_task public.catalog_collection_tasks%rowtype; v_count integer;
begin
  select * into v_task from public.catalog_collection_tasks
  where id = p_task_id and status = 'processing' and lease_token = p_lease_token and lease_until >= now()
  for update;
  if not found then raise exception 'Catalog task lease is missing or expired'; end if;
  insert into public.catalog_collection_pages(task_id, page_number, page_key, product_count)
  values (p_task_id, p_page_number, p_page_key, jsonb_array_length(p_products)) on conflict do nothing;
  if not found then return 0; end if;
  select public.record_catalog_batch(c.source_id, c.target_id, c.sync_run_id, p_products) into v_count
  from public.catalog_sync_cycles c where c.id = v_task.cycle_id;
  update public.catalog_collection_tasks
  set collected_count = collected_count + v_count, pages_count = greatest(pages_count, p_page_number), updated_at = now()
  where id = p_task_id;
  return v_count;
end $$;

create or replace function public.finish_catalog_collection_task(
  p_task_id uuid, p_lease_token uuid, p_complete boolean, p_expected_total integer,
  p_collected_count integer, p_pages_count integer, p_error text default null,
  p_rate_limited boolean default false, p_retry_after_seconds integer default null
) returns public.catalog_task_status language plpgsql security definer set search_path = public as $$
declare v_task public.catalog_collection_tasks%rowtype; v_cycle public.catalog_sync_cycles%rowtype;
declare v_status public.catalog_task_status; v_delay interval; v_unique_count integer; v_pages integer;
begin
  select * into v_task from public.catalog_collection_tasks
  where id = p_task_id and status = 'processing' and lease_token = p_lease_token and lease_until >= now() for update;
  if not found then raise exception 'Catalog task lease is missing or expired'; end if;
  select * into v_cycle from public.catalog_sync_cycles where id = v_task.cycle_id for update;
  if p_complete and p_expected_total is not null and p_collected_count >= p_expected_total and p_error is null then
    v_status := 'completed';
  elsif v_task.attempts >= 5 then v_status := 'blocked';
  else v_status := 'retryable'; end if;
  v_delay := case v_task.attempts when 1 then interval '5 minutes' when 2 then interval '15 minutes' else interval '60 minutes' end;
  update public.catalog_collection_tasks
  set status = v_status, expected_total = p_expected_total,
      collected_count = greatest(collected_count, p_collected_count), pages_count = greatest(pages_count, p_pages_count),
      next_attempt_at = case when v_status = 'retryable' then now() + v_delay else next_attempt_at end,
      lease_token = null, lease_until = null, last_error = p_error, completed_at = case when v_status = 'completed' then now() else null end,
      updated_at = now()
  where id = p_task_id;
  if p_rate_limited then
    insert into public.catalog_source_pauses(source_id, paused_until, reason)
    values (v_cycle.source_id, now() + greatest(coalesce(p_retry_after_seconds, 0), 3600) * interval '1 second', coalesce(p_error, 'ABOUT YOU rate limited'))
    on conflict (source_id) do update set paused_until = greatest(catalog_source_pauses.paused_until, excluded.paused_until), reason = excluded.reason, updated_at = now();
  end if;
  if not exists (select 1 from public.catalog_collection_tasks where cycle_id = v_cycle.id and status not in ('completed', 'blocked')) then
    select count(*) into v_unique_count
    from public.sync_target_products where target_id = v_cycle.target_id and last_seen_run_id = v_cycle.sync_run_id;
    select coalesce(sum(pages_count), 0) into v_pages
    from public.catalog_collection_tasks where cycle_id = v_cycle.id;
    if exists (select 1 from public.catalog_collection_tasks where cycle_id = v_cycle.id and status = 'blocked') then
      update public.catalog_sync_cycles set status = 'partial', finished_at = now(), error = 'One or more manifest parts were blocked.' where id = v_cycle.id;
      perform public.finish_sync_run(v_cycle.sync_run_id, 'partial', v_pages, v_unique_count, 'One or more catalog manifest parts were blocked.');
    else
      update public.catalog_sync_cycles set status = 'success', finished_at = now(), error = null where id = v_cycle.id;
      perform public.finish_sync_run(v_cycle.sync_run_id, 'success', v_pages, v_unique_count, null);
    end if;
  end if;
  return v_status;
end $$;

revoke all on table public.catalog_target_parts, public.catalog_sync_cycles, public.catalog_collection_tasks, public.catalog_collection_pages, public.catalog_source_pauses from public, anon, authenticated;
revoke all on function public.claim_catalog_collection_task(text), public.renew_catalog_collection_lease(uuid, uuid), public.record_catalog_collection_page(uuid, uuid, integer, text, jsonb), public.finish_catalog_collection_task(uuid, uuid, boolean, integer, integer, integer, text, boolean, integer) from public, anon, authenticated;
grant execute on function public.claim_catalog_collection_task(text), public.renew_catalog_collection_lease(uuid, uuid), public.record_catalog_collection_page(uuid, uuid, integer, text, jsonb), public.finish_catalog_collection_task(uuid, uuid, boolean, integer, integer, integer, text, boolean, integer) to service_role;
