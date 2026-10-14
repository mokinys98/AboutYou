-- VPS SQL Editor diagnostic while the catalog refresh cron is paused.
-- This counts the optimized view without projecting labels or sort_order.
-- It separates normalization/expansion cost from the full membership GROUP BY.
-- Expected: one EXPLAIN plan within 20 seconds. Send the plan or timeout;
-- do not rerun with a longer timeout.
begin read only;
set local statement_timeout = '20s';
set local lock_timeout = '2s';

explain (analyze, buffers, settings)
select count(*)
from public.catalog_size_facets_read_effective;

rollback;
