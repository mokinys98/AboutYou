-- VPS Supabase SQL Editor, read-only diagnostic after the failed catch-up.
-- This is the exact SELECT behind catalog_effective_size_membership_read.
-- EXPLAIN ANALYZE executes immutable normalization functions over the source.
-- If it reaches the 30-second timeout, send the error; do not rerun yet.
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
