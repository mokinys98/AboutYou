-- Keep transient network/server failures eligible for future refreshes.
-- Preserve existing function ownership, grants and lease checks.
begin;

create or replace function public.fail_product_detail(
  p_product_id uuid,
  p_lease_token uuid,
  p_error_kind text,
  p_error_code text,
  p_http_status integer default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_attempt integer;
begin
  select attempt_count into v_attempt
  from public.product_detail_sync
  where product_id = p_product_id and status = 'processing' and lease_token = p_lease_token
  for update;
  if not found then raise exception 'Product detail lease is missing'; end if;

  if p_error_kind = 'rate_limited' then
    update public.product_detail_sync set status = 'pending', next_attempt_at = now(),
      lease_token = null, lease_until = null, last_error_code = p_error_code,
      last_http_status = p_http_status, updated_at = now()
    where product_id = p_product_id;
  elsif p_error_kind = 'blocked_schema' then
    update public.product_detail_sync set status = 'blocked_schema', next_attempt_at = 'infinity',
      lease_token = null, lease_until = null, last_error_code = p_error_code,
      last_http_status = p_http_status, updated_at = now()
    where product_id = p_product_id;
  elsif p_error_kind = 'source_unavailable' then
    update public.product_detail_sync set status = 'source_unavailable', next_attempt_at = 'infinity',
      lease_token = null, lease_until = null, last_error_code = p_error_code,
      last_http_status = p_http_status, updated_at = now()
    where product_id = p_product_id;
  elsif p_error_kind = 'retryable' then
    v_attempt := v_attempt + 1;
    update public.product_detail_sync set status = 'retryable_error', attempt_count = v_attempt,
      next_attempt_at = case v_attempt when 1 then now() + interval '15 minutes'
        when 2 then now() + interval '2 hours' else now() + interval '24 hours' end,
      lease_token = null, lease_until = null, last_error_code = p_error_code,
      last_http_status = p_http_status, updated_at = now()
    where product_id = p_product_id;
  else
    raise exception 'Unknown product detail error kind';
  end if;

  update public.products set detail_checked_at = now(), detail_last_error = p_error_code
  where id = p_product_id;
end $$;


-- Recover only request timeouts stranded by the previous retry policy.
-- Spread recovery over six hours to avoid flooding the source.
update public.product_detail_sync
set next_attempt_at = now() + random() * interval '6 hours', updated_at = now()
where status = 'retryable_error'
  and next_attempt_at = 'infinity'::timestamptz
  and last_error_code = 'request_failed:product_detail_request_timeout';

commit;
