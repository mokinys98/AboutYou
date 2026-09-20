-- LOCAL DISPOSABLE DATABASE ONLY. Never run this fixture on the VPS.
\set ON_ERROR_STOP on
create table public.products (id uuid primary key, detail_checked_at timestamptz, detail_last_error text);
create table public.product_detail_sync (
  product_id uuid primary key, status text, lease_token uuid, lease_until timestamptz,
  attempt_count integer default 0, next_attempt_at timestamptz, updated_at timestamptz,
  last_error_code text, last_http_status integer
);
insert into public.products (id) values ('00000000-0000-0000-0000-000000000001');
insert into public.product_detail_sync (product_id, status, next_attempt_at)
values ('00000000-0000-0000-0000-000000000001', 'retryable_error', 'infinity');

\ir ../migrations/20260920190501_recover_transient_metadata_failures.sql

do $$
declare
  product uuid := '00000000-0000-0000-0000-000000000001';
  lease uuid := '00000000-0000-0000-0000-000000000002';
  next_time timestamptz;
begin
  select next_attempt_at into next_time from public.product_detail_sync where product_id = product;
  if next_time < now() or next_time > now() + interval '6 hours' then
    raise exception 'Old transient failure was not recovered';
  end if;
  update public.product_detail_sync set status = 'processing', attempt_count = 2,
    lease_token = lease, lease_until = now() + interval '20 minutes' where product_id = product;
  perform public.fail_product_detail(product, lease, 'retryable', 'timeout', null);
  if not exists (select 1 from public.product_detail_sync where product_id = product
      and status = 'retryable_error' and attempt_count = 3 and lease_token is null
      and next_attempt_at = now() + interval '24 hours') then
    raise exception 'Third transient failure must retry in 24 hours';
  end if;
  begin
    perform public.fail_product_detail(product, lease, 'retryable', 'stale lease', null);
    raise exception 'Stale lease was incorrectly accepted';
  exception when raise_exception then
    if sqlerrm <> 'Product detail lease is missing' then raise; end if;
  end;
  update public.product_detail_sync set status = 'processing', lease_token = lease where product_id = product;
  perform public.fail_product_detail(product, lease, 'blocked_schema', 'schema changed', 200);
  if not exists (select 1 from public.product_detail_sync where product_id = product
      and status = 'blocked_schema' and next_attempt_at = 'infinity') then
    raise exception 'Schema failures must still require a parser fix';
  end if;
end $$;
-- Reapplying must not change blocked_schema or privileges/ownership.
\ir ../migrations/20260920190501_recover_transient_metadata_failures.sql
select 'metadata retry policy passed' as result;
