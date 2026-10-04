-- Repeatable read-only timing of the static size dictionary calculation from
-- prepared effective membership. Run between catalog refresh cycles; the
-- refresh takes an AccessExclusiveLock on this view.
begin read only;

explain (analyze, buffers, format json)
with grouped as (
  select sf.domain_key,
    max(sf.domain_label) as domain_label,
    sf.value_key,
    max(sf.display_label) as display_label,
    sf.token,
    min(sf.sort_order) as sort_order
  from public.catalog_effective_size_membership_read sf
  group by sf.domain_key, sf.value_key, sf.token
)
select coalesce(jsonb_agg(jsonb_build_object(
  'value', grouped.token,
  'label', grouped.display_label,
  'domainKey', grouped.domain_key,
  'domainLabel', grouped.domain_label,
  'valueKey', grouped.value_key,
  'sortOrder', grouped.sort_order
) order by grouped.domain_key, grouped.sort_order, grouped.display_label), '[]'::jsonb)
from grouped;

rollback;
