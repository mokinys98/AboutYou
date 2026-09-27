-- Read-only inventory for Supabase SQL Editor. No RPC calls or data changes.
-- One row per configured part, with its latest observed task.
select t.id as target_id, t.label, t.url as target_url, t.enabled as target_enabled,
       p.part_key, p.url as part_url, p.enabled as part_enabled,
       latest.status as task_status, latest.attempts,
       latest.expected_total, latest.collected_count,
       latest.next_attempt_at, latest.last_error, latest.updated_at
from public.sync_targets t
left join public.catalog_target_parts p on p.target_id = t.id
left join lateral (
  select q.status, q.attempts, q.expected_total, q.collected_count,
         q.next_attempt_at, q.last_error, q.updated_at
  from public.catalog_collection_tasks q
  where q.part_id = p.id
  order by q.created_at desc, q.id desc
  limit 1
) latest on true
order by t.label, p.part_key;

-- Unique active product coverage across enabled targets. Target counts overlap.
select count(distinct stp.product_id) as unique_active_products_in_enabled_targets
from public.sync_target_products stp
join public.sync_targets t on t.id = stp.target_id
join public.products p on p.id = stp.product_id
where t.enabled and stp.active and p.active;

-- Queue state, including future retries and terminal states.
select q.status, count(*) as tasks,
       count(*) filter (where q.status in ('pending', 'retryable')
                         and q.next_attempt_at <= now()) as due_by_time,
       min(q.next_attempt_at) filter (where q.status in ('pending', 'retryable')) as earliest_attempt
from public.catalog_collection_tasks q
join public.catalog_sync_cycles c on c.id = q.cycle_id
join public.sync_targets t on t.id = c.target_id
join public.catalog_target_parts p on p.id = q.part_id
where c.status = 'running' and t.enabled and p.enabled
group by q.status order by q.status;
-- due_by_time does not account for catalog_source_pauses.
