-- One-time operational recovery for product metadata sync.
-- Requeues only expired processing leases (at most 100 per run).
-- Does not delete queue rows or product metadata, and preserves attempt_count.
begin;

with expired as (
  select sync.product_id
  from public.product_detail_sync sync
  where sync.status = 'processing'
    and sync.lease_until < now()
  order by sync.lease_until, sync.product_id
  limit 100
  for update skip locked
), requeued as (
  update public.product_detail_sync sync
  set status = 'pending',
      next_attempt_at = now(),
      lease_token = null,
      lease_until = null,
      updated_at = now()
  from expired
  where sync.product_id = expired.product_id
    and sync.status = 'processing'
    and sync.lease_until < now()
  returning sync.product_id
)
select count(*) as requeued_expired_leases from requeued;

-- Expected after one execution: requeued_expired_leases is at most 100;
-- no expired processing leases remain unless another lease expires concurrently.
select
  count(*) filter (where status = 'processing' and lease_until < now()) as expired_processing_leases,
  count(*) filter (where status = 'pending' and next_attempt_at <= now()) as due_pending,
  count(*) filter (where status = 'retryable_error' and next_attempt_at <= now()) as due_retryable
from public.product_detail_sync;

commit;
