-- Run after 20261006110000_remove_device_case_size_inference.sql and the next
-- naturally completed catalog refresh. Expected: all boolean fields are true.
begin read only;
set local statement_timeout = '15s';

with definition as (
  select lower(pg_get_functiondef('public.catalog_size_domain(text[],text[],text)'::regprocedure)) as body
), state as (
  select requested_version, completed_version, last_status, last_error
  from public.catalog_read_model_refresh_state
  where singleton
), root_cache as (
  select payload
  from public.catalog_facets_cache
  where filters = '{}'::jsonb
)
select
  position('device_cases' in definition.body) = 0 as name_no_longer_infers_device_cases,
  public.catalog_size_domain(array['vyrams>batai'], array['Batai'], 'Galaxy 8') = 'shoes'
    as galaxy_shoe_classifies_as_shoes,
  not exists (
    select 1 from public.catalog_effective_size_membership_read
    where domain_key = 'device_cases'
  ) as effective_membership_has_no_device_cases,
  not exists (
    select 1 from root_cache,
      jsonb_array_elements(coalesce(root_cache.payload->'sizes', '[]'::jsonb)) as size_entry(value)
    where size_entry.value->>'domainKey' = 'device_cases'
  ) as root_facets_have_no_device_cases,
  exists (select 1 from root_cache) as root_cache_present,
  (select requested_version = completed_version
    and last_status in ('clean', 'refreshed') and last_error is null from state)
    as refresh_current_and_successful,
  (select requested_version from state) as catalog_version
from definition;

rollback;
