-- Run in VPS SQL Editor only after the precomputed-components migration and
-- its separate read-only definition check. Keep 5-minute cron paused.
-- Expected: full plan completes within 30 seconds; output is ~372k rows.
-- Send the complete plan or error. Do not extend the timeout or run catch-up.
begin read only;
set local statement_timeout = '30s';
set local lock_timeout = '2s';

explain (analyze, buffers, settings)
select
  product_id,
  domain_key,
  max(domain_label) as domain_label,
  value_key,
  max(display_label) as display_label,
  token,
  min(sort_order) as sort_order
from public.catalog_size_facets_read_effective
group by product_id, domain_key, value_key, token;

rollback;
