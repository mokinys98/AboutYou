-- Apply per-size overrides to the effective size facet read model.

create or replace view public.catalog_size_facets_read_effective as
with source_values as (
  select sf.product_id,
    coalesce(o.size_domain, public.catalog_size_domain(i.category_paths, i.category_names, i.name)) as domain_key,
    sf.value_key as source_value_key,
    sf.display_label as source_display_label,
    sf.sort_order,
    ov.value as value_override
  from public.catalog_size_facets_read sf
  join public.catalog_items_read i on i.id = sf.product_id
  left join public.catalog_size_classification_overrides o on o.product_id = sf.product_id
  left join lateral jsonb_each(coalesce(o.size_value_overrides, '{}'::jsonb)) ov
    on ov.key = sf.display_label
  where coalesce(o.exclude_from_size_filter, false) = false
), normalized as (
  select product_id, domain_key,
    public.catalog_size_domain_label(domain_key) as domain_label,
    case when value_override is null then source_value_key
      else public.catalog_size_value_key(
        coalesce(nullif(trim(value_override->>'label'), ''), source_display_label)
        || case when nullif(trim(value_override->>'sizeGroup'), '') is not null
          then '-' || trim(value_override->>'sizeGroup') else '' end
      ) end as value_key,
    case when value_override is null then source_display_label
      else coalesce(nullif(trim(value_override->>'label'), ''), source_display_label)
        || case when nullif(trim(value_override->>'sizeGroup'), '') is not null
          then ' / ' || trim(value_override->>'sizeGroup') else '' end
      end as display_label,
    sort_order
  from source_values
)
select product_id, domain_key, domain_label, value_key, display_label,
  domain_key || ':' || value_key as token, sort_order
from normalized;

revoke all on table public.catalog_size_facets_read_effective from public, anon, authenticated;
grant select on table public.catalog_size_facets_read_effective to service_role;

delete from public.catalog_facets_cache;
notify pgrst, 'reload schema';
