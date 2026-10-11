-- Run in VPS Supabase SQL Editor only after the matching migration is
-- confirmed by verify_effective_size_normalization_view_read_only.sql.
-- Cron must remain paused. Expected: completed plan under 30 seconds and
-- about 372k output rows; send the full plan. If SQL Editor times out,
-- send the error and do not retry with a longer timeout.
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
