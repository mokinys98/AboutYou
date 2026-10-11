-- Run after applying the matching migration in VPS Supabase SQL Editor.
-- Expected: two rows, both with all four configured reloptions shown below.
begin read only;

select
  c.relname,
  pg_get_userbyid(c.relowner) as owner,
  c.reloptions,
  c.reloptions @> array[
    'autovacuum_vacuum_threshold=500',
    'autovacuum_vacuum_scale_factor=0.02',
    'autovacuum_analyze_threshold=500',
    'autovacuum_analyze_scale_factor=0.02'
  ] as expected_options_present,
  s.n_live_tup,
  s.n_dead_tup,
  s.last_autovacuum,
  s.last_autoanalyze
from pg_class c
join pg_stat_all_tables s on s.relid = c.oid
where c.oid in (
  'public.catalog_items_read'::regclass,
  'public.catalog_item_facet_values_read'::regclass
)
order by c.relname;

rollback;
