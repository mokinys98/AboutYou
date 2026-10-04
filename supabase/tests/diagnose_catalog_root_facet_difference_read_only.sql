-- Run in VPS Supabase SQL Editor after applying the root facet migration.
-- Compares each top-level field without writing a cache entry. For array
-- fields, unordered_equal distinguishes value/count differences from an
-- ordering difference. The expensive original function runs once.
begin read only;
set local statement_timeout = '45s';

with payloads as materialized (
  select
    public.catalog_facets('{}'::jsonb) as original,
    public.catalog_root_facets() as optimized
), fields as (
  select key,
    original -> key as original_value,
    optimized -> key as optimized_value
  from payloads,
    lateral jsonb_object_keys(original || optimized) as keys(key)
)
select
  key,
  original_value = optimized_value as exact_equal,
  case when jsonb_typeof(original_value) = 'array'
    and jsonb_typeof(optimized_value) = 'array' then
    (select jsonb_agg(value order by value::text)
     from jsonb_array_elements(original_value) as a(value))
    is not distinct from
    (select jsonb_agg(value order by value::text)
     from jsonb_array_elements(optimized_value) as b(value))
  end as unordered_equal,
  case when jsonb_typeof(original_value) = 'array'
    then jsonb_array_length(original_value) end as original_items,
  case when jsonb_typeof(optimized_value) = 'array'
    then jsonb_array_length(optimized_value) end as optimized_items,
  case when jsonb_typeof(original_value) <> 'array'
    and original_value is distinct from optimized_value
    then original_value end as original_scalar,
  case when jsonb_typeof(optimized_value) <> 'array'
    and original_value is distinct from optimized_value
    then optimized_value end as optimized_scalar
from fields
order by key;

rollback;
