-- Expand normalized size components and compute their deterministic labels and
-- sort order once per distinct normalization input rather than once per source
-- product row. Preserve row-specific fallback labels after joining back.
-- This changes the view definition only; it does not refresh any materialized view.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

do $$
declare
  v_owner text;
  v_definition text;
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  select pg_get_userbyid(c.relowner), pg_get_viewdef(c.oid, true)
  into v_owner, v_definition
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'catalog_size_facets_read_effective'
    and c.relkind = 'v';

  if v_definition is null then
    raise exception 'Expected public.catalog_size_facets_read_effective to be a view';
  end if;

  if v_owner <> current_user then
    raise exception 'View public.catalog_size_facets_read_effective is owned by %, not %',
      v_owner, current_user;
  end if;

  -- Fingerprint of the current VPS view inspected read-only after applying
  -- 20261011190000_deduplicate_effective_size_normalization.sql.
  if md5(v_definition) <> '3779920dbe0f68902912fb2dca60b6b7' then
    raise exception 'Unexpected definition of public.catalog_size_facets_read_effective; inspect VPS before applying';
  end if;
end;
$$;

create or replace view public.catalog_size_facets_read_effective as
with source_values as materialized (
  select
    sf.product_id,
    coalesce(o.size_domain, sf.domain_key) as domain_key,
    sf.value_key as source_value_key,
    sf.display_label as source_display_label,
    sf.sort_order,
    o.size_value_overrides -> sf.display_label as value_override,
    case
      when o.size_value_overrides -> sf.display_label is null then sf.display_label
      else coalesce(nullif(trim((o.size_value_overrides -> sf.display_label)->>'label'), ''), sf.display_label)
        || case
          when nullif(trim((o.size_value_overrides -> sf.display_label)->>'sizeGroup'), '') is not null
            then ' / ' || trim((o.size_value_overrides -> sf.display_label)->>'sizeGroup')
          else ''
        end
    end as normalization_input
  from public.catalog_size_facets_read sf
  left join public.catalog_size_classification_overrides o
    on o.product_id = sf.product_id
  where coalesce(o.exclude_from_size_filter, false) = false
), distinct_inputs as materialized (
  select distinct domain_key, normalization_input, source_value_key
  from source_values
), input_features as materialized (
  select
    domain_key,
    normalization_input,
    source_value_key,
    public.catalog_size_domain_label(domain_key) as domain_label,
    public.catalog_strip_known_size_description(normalization_input) as stripped_description,
    public.catalog_effective_size_value_key(source_value_key) as original_key,
    case when domain_key = 'trousers'
      then public.catalog_normalize_trouser_size_value(normalization_input)
    end as trouser_value_key
  from distinct_inputs
), normalized_inputs as materialized (
  select
    input_features.*,
    public.catalog_effective_size_value_key(
      domain_key,
      coalesce(stripped_description, normalization_input)
    ) as stripped_value_key,
    public.catalog_effective_size_value_key(domain_key, normalization_input) as fallback_value_key
  from input_features
), normalized_components as materialized (
  select
    normalized_inputs.*,
    coalesce(trouser_value_key, stripped_value_key, fallback_value_key) as value_key
  from normalized_inputs
), expanded_components as materialized (
  select
    normalized_components.*,
    component.value_key as facet_value_key
  from normalized_components
  cross join lateral unnest(
    case
      when domain_key in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear', 'gloves', 'headwear', 'socks')
        and value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)-(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'
        then string_to_array(value_key, '-')
      else array[value_key]
    end
  ) as component(value_key)
), prepared_components as materialized (
  select
    expanded_components.*,
    case
      when value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'
        then upper(value_key)
      when value_key ~ '^w[0-9]{2,3}-l[0-9]{2,3}$'
        then 'W' || substring(value_key from '^w([0-9]{2,3})') || ' × L'
          || substring(value_key from '-l([0-9]{2,3})$')
      when value_key = 'one-size' then 'Vienas dydis'
      when value_key is null then null
      when stripped_description is not null then value_key
      when value_key <> original_key then value_key
      else null
    end as fixed_display_label,
    public.catalog_effective_size_sort_order(facet_value_key) as facet_sort_order
  from expanded_components
), facet_components as materialized (
  select *
  from prepared_components
  where facet_value_key is not null
)
select
  source_values.product_id,
  source_values.domain_key,
  facet_components.domain_label,
  facet_components.facet_value_key as value_key,
  case
    when facet_components.facet_value_key <> facet_components.value_key
      then upper(facet_components.facet_value_key)
    else coalesce(
      facet_components.fixed_display_label,
      coalesce(nullif(trim(source_values.value_override->>'label'), ''), source_values.source_display_label)
    )
  end as display_label,
  source_values.domain_key || ':' || facet_components.facet_value_key as token,
  facet_components.facet_sort_order as sort_order
from source_values
join facet_components
  on coalesce(source_values.domain_key, '') = coalesce(facet_components.domain_key, '')
  and (source_values.domain_key is null) = (facet_components.domain_key is null)
  and coalesce(source_values.normalization_input, '') = coalesce(facet_components.normalization_input, '')
  and (source_values.normalization_input is null) = (facet_components.normalization_input is null)
  and coalesce(source_values.source_value_key, '') = coalesce(facet_components.source_value_key, '')
  and (source_values.source_value_key is null) = (facet_components.source_value_key is null);

commit;
