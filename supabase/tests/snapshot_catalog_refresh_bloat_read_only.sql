-- Run immediately before and after each real catalog refresh. Save both
-- result sets with their checked_at_utc timestamps; compare counters only
-- when stats_reset_at is unchanged. n_dead_tup is an estimate, not measured
-- physical bloat. This query never starts a refresh or changes the database.
begin read only;
set local statement_timeout = '10s';

select
  clock_timestamp() as checked_at_utc,
  d.stats_reset as stats_reset_at,
  c.relname as relation_name,
  c.relkind,
  s.n_live_tup,
  s.n_dead_tup,
  s.n_tup_ins,
  s.n_tup_upd,
  s.n_tup_del,
  s.vacuum_count,
  s.autovacuum_count,
  s.last_vacuum,
  s.last_autovacuum,
  pg_relation_size(c.oid) as heap_bytes,
  pg_indexes_size(c.oid) as index_bytes,
  pg_total_relation_size(c.oid) as total_bytes
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_stat_all_tables s on s.relid = c.oid
cross join pg_stat_database d
where n.nspname = 'public'
  and d.datname = current_database()
  and c.relname in (
    'catalog_items_read',
    'catalog_item_facet_values_read',
    'catalog_size_facets_read',
    'catalog_effective_size_membership_read',
    'catalog_facets_cache',
    'catalog_static_size_facets_cache'
  )
order by c.relname;

rollback;
