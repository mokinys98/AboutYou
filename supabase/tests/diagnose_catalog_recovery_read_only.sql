-- Read-only incident snapshot for catalog refresh and metadata recovery.
-- Run in Supabase SQL Editor. This does not start a refresh or modify data.
begin read only;

-- Refresh backlog and the latest failure phase.
select
  clock_timestamp() as checked_at_utc,
  requested_version,
  completed_version,
  requested_version - completed_version as pending_versions,
  last_status,
  last_duration_ms,
  last_error,
  refresh_started_at,
  refresh_completed_at
from public.catalog_read_model_refresh_state
where singleton;

-- Largest public tables, including live/dead tuple estimates and heap/index sizes.
select
  s.relname as table_name,
  s.n_live_tup as live_rows_estimate,
  s.n_dead_tup as dead_rows_estimate,
  pg_size_pretty(pg_relation_size(s.relid)) as heap_size,
  pg_size_pretty(pg_indexes_size(s.relid)) as indexes_size,
  pg_size_pretty(pg_total_relation_size(s.relid)) as total_size,
  s.last_autovacuum,
  s.last_autoanalyze
from pg_stat_user_tables s
where s.schemaname = 'public'
order by pg_total_relation_size(s.relid) desc
limit 60;

-- Index inventory and cumulative usage for the refresh source and read model.
-- Usage counters may have been reset, so interpret them with stats_reset.
select
  i.relname as table_name,
  ix.relname as index_name,
  pg_size_pretty(pg_relation_size(ix.oid)) as index_size,
  coalesce(u.idx_scan, 0) as scans_since_stats_reset,
  coalesce(u.idx_tup_read, 0) as tuples_read,
  coalesce(u.idx_tup_fetch, 0) as tuples_fetched
from pg_index pi
join pg_class i on i.oid = pi.indrelid
join pg_class ix on ix.oid = pi.indexrelid
join pg_namespace n on n.oid = i.relnamespace
left join pg_stat_user_indexes u on u.indexrelid = ix.oid
where n.nspname = 'public'
  and i.relname in (
    'products', 'sources', 'offers', 'product_categories', 'categories',
    'brand_tiers', 'catalog_items_read'
  )
order by i.relname, pg_relation_size(ix.oid) desc;

-- Bounded view of active database work and waits with truncated SQL text.
select
  pid,
  state,
  wait_event_type,
  wait_event,
  clock_timestamp() - query_start as query_age,
  clock_timestamp() - xact_start as transaction_age,
  left(query, 240) as query_preview
from pg_stat_activity
where datname = current_database()
  and pid <> pg_backend_pid()
  and state <> 'idle'
order by query_start nulls last
limit 20;

-- Metadata queue health, grouped without product payloads or URLs.
select
  status,
  case
    when last_error_code is null then null
    when last_error_code like 'request_failed:%' then 'request_failed'
    else left(last_error_code, 64)
  end as error_class,
  last_http_status,
  count(*) as products,
  count(*) filter (where next_attempt_at is null or next_attempt_at <= now()) as due_now,
  count(*) filter (where status = 'processing' and lease_until < now()) as expired_leases,
  min(updated_at) as oldest_updated_at,
  max(updated_at) as newest_updated_at
from public.product_detail_sync
group by status,
  case
    when last_error_code is null then null
    when last_error_code like 'request_failed:%' then 'request_failed'
    else left(last_error_code, 64)
  end,
  last_http_status
order by count(*) desc
limit 30;

-- Catalog collection cycle/task health. Retryable work may be waiting for its
-- configured backoff and should not be force-requeued during diagnosis.
select
  cycle.status::text as cycle_status,
  count(distinct cycle.id) as cycles,
  count(task.id) filter (where task.status::text = 'processing') as processing_tasks,
  count(task.id) filter (where task.status::text = 'pending') as pending_tasks,
  count(task.id) filter (where task.status::text = 'retryable') as retryable_tasks,
  count(task.id) filter (where task.status::text = 'blocked') as blocked_tasks,
  min(cycle.started_at) as oldest_cycle_started_at,
  max(clock_timestamp() - cycle.started_at) filter (where cycle.status::text = 'running') as oldest_running_age
from public.catalog_sync_cycles cycle
left join public.catalog_collection_tasks task on task.cycle_id = cycle.id
group by cycle.status
order by count(distinct cycle.id) desc;

rollback;
