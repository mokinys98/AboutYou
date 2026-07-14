-- Seed product-detail work once, when a product is first created. The previous
-- claim function rechecked every active product for every 25-row claim.
create or replace function public.initialize_product_detail_sync() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.product_detail_sync(product_id)
  values (new.id)
  on conflict (product_id) do nothing;
  return new;
end;
$$;

revoke all on function public.initialize_product_detail_sync() from public, anon, authenticated;

drop trigger if exists products_initialize_product_detail_sync on public.products;
create trigger products_initialize_product_detail_sync
after insert on public.products
for each row execute function public.initialize_product_detail_sync();

insert into public.product_detail_sync(product_id)
select product.id
from public.products product
left join public.product_detail_sync sync on sync.product_id = product.id
where sync.product_id is null
on conflict (product_id) do nothing;

create or replace function public.claim_product_detail_batch(
  p_parser_version integer,
  p_limit integer default 25,
  p_lease_minutes integer default 20
) returns table (
  id uuid,
  source_id uuid,
  external_id text,
  name text,
  brand text,
  product_url text,
  lease_token uuid
) language plpgsql security definer set search_path = public as $$
declare
  v_lease_token uuid := gen_random_uuid();
begin
  if p_parser_version <= 0 or p_limit < 1 or p_limit > 500 or p_lease_minutes < 1 or p_lease_minutes > 60 then
    raise exception 'Invalid product detail claim parameters';
  end if;

  return query
  with candidates as (
    select sync.product_id, product.product_url
    from public.product_detail_sync sync
    join public.products product on product.id = sync.product_id and product.active
    where
      sync.parser_version < p_parser_version
      or (sync.status in ('pending', 'retryable_error', 'complete') and sync.next_attempt_at <= now())
      or (sync.status = 'processing' and sync.lease_until < now())
      or (sync.status = 'source_unavailable' and sync.source_url is distinct from product.product_url)
    order by
      case when sync.parser_version < p_parser_version then 0
           when sync.status in ('pending', 'retryable_error') then 1
           when sync.status = 'processing' then 2 else 3 end,
      sync.next_attempt_at,
      sync.availability_synced_at nulls first,
      sync.product_id
    limit p_limit
    for update of sync skip locked
  ), claimed as (
    update public.product_detail_sync sync set
      status = 'processing',
      parser_version = p_parser_version,
      attempt_count = case when sync.parser_version <> p_parser_version then 0 else sync.attempt_count end,
      lease_token = v_lease_token,
      lease_until = now() + make_interval(mins => p_lease_minutes),
      last_error_code = null,
      last_http_status = null,
      source_url = candidates.product_url,
      updated_at = now()
    from candidates
    where sync.product_id = candidates.product_id
    returning sync.product_id
  )
  select product.id, product.source_id, product.external_id, product.name, product.brand,
    product.product_url, v_lease_token
  from claimed
  join public.products product on product.id = claimed.product_id
  order by product.id;
end;
$$;

revoke all on function public.claim_product_detail_batch(integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.claim_product_detail_batch(integer, integer, integer) to service_role;

-- A monotonically increasing requested version prevents a refresh request that
-- arrives during a rebuild from being cleared by the older rebuild.
create table public.catalog_read_model_refresh_state (
  singleton boolean primary key default true check (singleton),
  requested_version bigint not null default 0 check (requested_version >= 0),
  completed_version bigint not null default 0 check (
    completed_version >= 0 and completed_version <= requested_version
  ),
  requested_at timestamptz,
  refresh_started_at timestamptz,
  refresh_completed_at timestamptz,
  last_status text not null default 'pending' check (
    last_status in ('pending', 'clean', 'refreshed', 'failed')
  ),
  last_duration_ms bigint check (last_duration_ms is null or last_duration_ms >= 0),
  last_error text,
  updated_at timestamptz not null default now()
);

alter table public.catalog_read_model_refresh_state enable row level security;
revoke all on table public.catalog_read_model_refresh_state from public, anon, authenticated;
grant select on table public.catalog_read_model_refresh_state to service_role;

insert into public.catalog_read_model_refresh_state(
  singleton, requested_version, completed_version, requested_at, last_status
) values (true, 1, 0, now(), 'pending');

create or replace function public.request_catalog_items_read_refresh() returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_requested_version bigint;
begin
  insert into public.catalog_read_model_refresh_state as state(
    singleton, requested_version, completed_version, requested_at, last_status, updated_at
  ) values (true, 1, 0, now(), 'pending', now())
  on conflict (singleton) do update set
    requested_version = state.requested_version + 1,
    requested_at = excluded.requested_at,
    last_status = 'pending',
    updated_at = excluded.updated_at
  returning requested_version into v_requested_version;

  return v_requested_version;
end;
$$;

revoke all on function public.request_catalog_items_read_refresh() from public, anon, authenticated;
grant execute on function public.request_catalog_items_read_refresh() to service_role;

create or replace function public.rebuild_catalog_items_read_internal() returns void
language plpgsql security definer
set search_path = public, pg_temp
set statement_timeout = '90s'
set lock_timeout = '3s' as $$
begin
  execute 'refresh materialized view concurrently public.catalog_items_read';
  execute 'refresh materialized view public.catalog_item_facet_values_read';
  delete from public.catalog_facets_cache;
  insert into public.catalog_facets_cache(filters, payload)
  values ('{}'::jsonb, public.catalog_facets('{}'::jsonb));
end;
$$;

revoke all on function public.rebuild_catalog_items_read_internal()
  from public, anon, authenticated, service_role;

create or replace function public.process_catalog_items_read_refresh() returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
set statement_timeout = '100s'
set lock_timeout = '3s' as $$
declare
  v_target_version bigint;
  v_completed_version bigint;
  v_requested_after bigint;
  v_started_at timestamptz := clock_timestamp();
  v_duration_ms bigint;
  v_error_state text;
  v_error_message text;
begin
  if not pg_try_advisory_xact_lock(hashtext('catalog_items_read_refresh')) then
    return jsonb_build_object('status', 'busy');
  end if;

  select requested_version, completed_version
  into v_target_version, v_completed_version
  from public.catalog_read_model_refresh_state
  where singleton;

  if v_target_version is null or v_completed_version >= v_target_version then
    update public.catalog_read_model_refresh_state
    set last_status = 'clean', last_error = null, updated_at = now()
    where singleton;
    return jsonb_build_object(
      'status', 'clean',
      'requestedVersion', coalesce(v_target_version, 0),
      'completedVersion', coalesce(v_completed_version, 0)
    );
  end if;

  begin
    perform public.rebuild_catalog_items_read_internal();
  exception
    when query_canceled then
      get stacked diagnostics v_error_state = returned_sqlstate, v_error_message = message_text;
      v_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_started_at)) * 1000));
      update public.catalog_read_model_refresh_state
      set refresh_started_at = v_started_at,
          refresh_completed_at = clock_timestamp(),
          last_status = 'failed',
          last_duration_ms = v_duration_ms,
          last_error = left(v_error_state || ': ' || v_error_message, 1000),
          updated_at = now()
      where singleton;
      return jsonb_build_object('status', 'failed', 'error', v_error_state, 'durationMs', v_duration_ms);
    when others then
      get stacked diagnostics v_error_state = returned_sqlstate, v_error_message = message_text;
      v_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_started_at)) * 1000));
      update public.catalog_read_model_refresh_state
      set refresh_started_at = v_started_at,
          refresh_completed_at = clock_timestamp(),
          last_status = 'failed',
          last_duration_ms = v_duration_ms,
          last_error = left(v_error_state || ': ' || v_error_message, 1000),
          updated_at = now()
      where singleton;
      return jsonb_build_object('status', 'failed', 'error', v_error_state, 'durationMs', v_duration_ms);
  end;

  v_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_started_at)) * 1000));
  update public.catalog_read_model_refresh_state
  set completed_version = greatest(completed_version, v_target_version),
      refresh_started_at = v_started_at,
      refresh_completed_at = clock_timestamp(),
      last_status = 'refreshed',
      last_duration_ms = v_duration_ms,
      last_error = null,
      updated_at = now()
  where singleton
  returning requested_version into v_requested_after;

  return jsonb_build_object(
    'status', 'refreshed',
    'requestedVersion', v_requested_after,
    'completedVersion', v_target_version,
    'dirty', v_requested_after > v_target_version,
    'durationMs', v_duration_ms
  );
end;
$$;

revoke all on function public.process_catalog_items_read_refresh() from public, anon, authenticated;
grant execute on function public.process_catalog_items_read_refresh() to service_role;

-- Compatibility for callers deployed before this migration. New callers only
-- request a refresh and let the cron worker perform it.
create or replace function public.refresh_catalog_items_read() returns void
language plpgsql security definer
set search_path = public, pg_temp
set statement_timeout = '100s'
set lock_timeout = '3s' as $$
begin
  perform public.request_catalog_items_read_refresh();
  perform public.process_catalog_items_read_refresh();
end;
$$;

revoke all on function public.refresh_catalog_items_read() from public, anon, authenticated;
grant execute on function public.refresh_catalog_items_read() to service_role;

drop index if exists public.catalog_item_facet_values_read_group_idx;

create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

select cron.schedule(
  'catalog-read-model-refresh',
  '*/5 * * * *',
  $cron$select public.process_catalog_items_read_refresh();$cron$
);

select cron.schedule(
  'catalog-read-model-refresh-history-cleanup',
  '15 3 * * *',
  $cron$
    delete from cron.job_run_details
    where jobid in (
      select jobid from cron.job
      where jobname in (
        'catalog-read-model-refresh',
        'catalog-read-model-refresh-history-cleanup'
      )
    )
      and end_time < now() - interval '14 days';
  $cron$
);

notify pgrst, 'reload schema';
