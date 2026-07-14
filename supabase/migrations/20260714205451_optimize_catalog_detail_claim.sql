-- Drive each priority class in claim order and stop after the requested batch.
-- This avoids sorting every eligible sync row before claiming 25 products.
create index product_detail_sync_claim_order_idx
  on public.product_detail_sync (
    next_attempt_at,
    availability_synced_at nulls first,
    product_id
  ) include (parser_version, status, lease_until);

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
  with old_version as materialized (
    select sync.product_id
    from public.product_detail_sync sync
    where sync.parser_version < p_parser_version
      and exists (
        select 1 from public.products product
        where product.id = sync.product_id and product.active
      )
    order by sync.next_attempt_at, sync.availability_synced_at nulls first, sync.product_id
    limit p_limit
    for update of sync skip locked
  ), due_pending as materialized (
    select sync.product_id
    from public.product_detail_sync sync
    where sync.parser_version >= p_parser_version
      and sync.status in ('pending', 'retryable_error')
      and sync.next_attempt_at <= now()
      and exists (
        select 1 from public.products product
        where product.id = sync.product_id and product.active
      )
    order by sync.next_attempt_at, sync.availability_synced_at nulls first, sync.product_id
    limit greatest(0, p_limit - (select count(*) from old_version))
    for update of sync skip locked
  ), expired_processing as materialized (
    select sync.product_id
    from public.product_detail_sync sync
    where sync.parser_version >= p_parser_version
      and sync.status = 'processing'
      and sync.lease_until < now()
      and exists (
        select 1 from public.products product
        where product.id = sync.product_id and product.active
      )
    order by sync.next_attempt_at, sync.availability_synced_at nulls first, sync.product_id
    limit greatest(
      0,
      p_limit - (select count(*) from old_version) - (select count(*) from due_pending)
    )
    for update of sync skip locked
  ), remaining as materialized (
    select sync.product_id
    from public.product_detail_sync sync
    join public.products product on product.id = sync.product_id and product.active
    where sync.parser_version >= p_parser_version
      and (
        (sync.status = 'complete' and sync.next_attempt_at <= now())
        or (
          sync.status = 'source_unavailable'
          and sync.source_url is distinct from product.product_url
        )
      )
    order by sync.next_attempt_at, sync.availability_synced_at nulls first, sync.product_id
    limit greatest(
      0,
      p_limit
        - (select count(*) from old_version)
        - (select count(*) from due_pending)
        - (select count(*) from expired_processing)
    )
    for update of sync skip locked
  ), candidates as (
    select product_id from old_version
    union all
    select product_id from due_pending
    union all
    select product_id from expired_processing
    union all
    select product_id from remaining
  ), claimed as (
    update public.product_detail_sync sync set
      status = 'processing',
      parser_version = p_parser_version,
      attempt_count = case when sync.parser_version <> p_parser_version then 0 else sync.attempt_count end,
      lease_token = v_lease_token,
      lease_until = now() + make_interval(mins => p_lease_minutes),
      last_error_code = null,
      last_http_status = null,
      source_url = product.product_url,
      updated_at = now()
    from candidates
    join public.products product on product.id = candidates.product_id
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
