-- Run only after verify_optimized_catalog_size_facets_stage_read_only.sql
-- returns stage_populated=true. An unpopulated materialized view cannot be
-- queried, even behind a CASE expression.
begin read only;
set local statement_timeout = '10s';

select
  clock_timestamp() as checked_at_utc,
  count(*) as stage_rows
from public.catalog_size_facets_read_optimized_stage;

rollback;
