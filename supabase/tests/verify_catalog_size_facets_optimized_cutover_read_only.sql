-- Read-only verification after applying
-- 20261017195000_switch_catalog_size_facets_to_optimized_stage.sql.
-- Returns one result grid with cutover state repeated on each expected index.
-- Expected: cron_paused=true, production/backup ready, effective view uses
-- the new MV only, backup hidden from API roles, and all three indexes valid.
begin read only;
set local statement_timeout = '5s';

with cutover as (
  select
    clock_timestamp() as checked_at_utc,
    (select count(*) = 1 and coalesce(bool_and(not j.active), false)
     from cron.job j
     where j.jobname = 'catalog-read-model-refresh'
       and j.schedule = '*/5 * * * *'
       and j.command ilike '%process_catalog_items_read_refresh()%') as cron_paused,
    prod_mv.relkind = 'm' and prod_mv.relispopulated as production_mv_ready,
    pg_get_userbyid(prod_mv.relowner) as production_mv_owner,
    pg_size_pretty(pg_total_relation_size(prod_mv.oid)) as production_mv_total_size,
    has_table_privilege('anon', prod_mv.oid, 'SELECT') as anon_can_select,
    has_table_privilege('authenticated', prod_mv.oid, 'SELECT') as authenticated_can_select,
    has_table_privilege('service_role', prod_mv.oid, 'SELECT') as service_role_can_select,
    backup_mv.relkind = 'm' and backup_mv.relispopulated as rollback_backup_ready,
    has_table_privilege('anon', backup_mv.oid, 'SELECT') as anon_can_read_backup,
    has_table_privilege('authenticated', backup_mv.oid, 'SELECT') as authenticated_can_read_backup,
    has_table_privilege('service_role', backup_mv.oid, 'SELECT') as service_role_can_read_backup,
    exists (
      select 1 from pg_depend d
      join pg_rewrite rw on rw.oid = d.objid
      where rw.ev_class = 'public.catalog_size_facets_read_effective'::regclass
        and d.refobjid = prod_mv.oid
    ) as effective_view_uses_new_mv,
    not exists (
      select 1 from pg_depend d
      join pg_rewrite rw on rw.oid = d.objid
      where rw.ev_class = 'public.catalog_size_facets_read_effective'::regclass
        and d.refobjid = backup_mv.oid
    ) as effective_view_detached_from_backup,
    state.requested_version,
    state.completed_version,
    state.requested_version - state.completed_version as version_gap,
    state.last_status,
    state.refresh_completed_at
  from pg_class prod_mv
  cross join pg_class backup_mv
  cross join public.catalog_read_model_refresh_state state
  where prod_mv.oid = 'public.catalog_size_facets_read'::regclass
    and backup_mv.oid = 'public.catalog_size_facets_read_backup_20261017'::regclass
    and state.singleton
), expected_indexes(index_name) as (
  values
    ('catalog_size_facets_read_optimized_stage_domain_idx'::text),
    ('catalog_size_facets_read_optimized_stage_token_idx'::text),
    ('catalog_size_facets_read_optimized_stage_unique_idx'::text)
), index_details as (
  select
    e.index_name,
    i.indexrelid is not null as index_present,
    i.indisunique as is_unique,
    i.indisvalid as is_valid,
    i.indisready as is_ready,
    pg_get_indexdef(i.indexrelid) as index_definition,
    pg_size_pretty(pg_relation_size(i.indexrelid)) as index_size
  from expected_indexes e
  left join pg_class ci
    on ci.relname = e.index_name
   and ci.relnamespace = 'public'::regnamespace
  left join pg_index i
    on i.indexrelid = ci.oid
   and i.indrelid = 'public.catalog_size_facets_read'::regclass
)
select cutover.*, index_details.*
from cutover
cross join index_details
order by index_details.index_name;

rollback;
