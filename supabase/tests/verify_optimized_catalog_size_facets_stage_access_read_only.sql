-- Run after applying 20261017171000_lock_down_optimized_catalog_size_stage.sql.
-- Expected: anon_can_select=false, authenticated_can_select=false,
-- public_can_select=false, service_role_can_select=true.
begin read only;

select
  clock_timestamp() as checked_at_utc,
  c.relkind = 'm' as is_materialized_view,
  c.relispopulated as stage_populated,
  has_table_privilege('anon', c.oid, 'SELECT') as anon_can_select,
  has_table_privilege('authenticated', c.oid, 'SELECT') as authenticated_can_select,
  exists (
    select 1
    from aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
    where a.grantee = 0
      and a.privilege_type = 'SELECT'
  ) as public_can_select,
  has_table_privilege('service_role', c.oid, 'SELECT') as service_role_can_select
from pg_class c
where c.oid = 'public.catalog_size_facets_read_optimized_stage'::regclass;

rollback;
