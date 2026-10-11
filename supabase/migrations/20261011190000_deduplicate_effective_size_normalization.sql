-- Evaluate immutable size normalization functions once per distinct input tuple
-- instead of once per source product row. Incident measurements found only
-- 2,503 distinct (domain, normalization input, source key) tuples across
-- 375,751 rows.
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

  -- Fingerprint of the complete VPS view definition inspected read-only on
  -- 2026-10-11. Abort if any expression changed since that inspection.
  if md5(v_definition) <> '713f5e880cbea0cac534b24f54a7be02' then
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
), normalized_keys as (
  select
    source_values.product_id,
    source_values.domain_key,
    normalized_inputs.domain_label,
    coalesce(
      normalized_inputs.trouser_value_key,
      normalized_inputs.stripped_value_key,
      normalized_inputs.fallback_value_key
    ) as value_key,
    normalized_inputs.original_key,
    source_values.source_display_label,
    source_values.value_override,
    source_values.sort_order,
    normalized_inputs.stripped_description,
    normalized_inputs.stripped_description is not null as had_known_description
  from source_values
  join normalized_inputs
    on coalesce(source_values.domain_key, '') = coalesce(normalized_inputs.domain_key, '')
    and (source_values.domain_key is null) = (normalized_inputs.domain_key is null)
    and coalesce(source_values.normalization_input, '') = coalesce(normalized_inputs.normalization_input, '')
    and (source_values.normalization_input is null) = (normalized_inputs.normalization_input is null)
    and coalesce(source_values.source_value_key, '') = coalesce(normalized_inputs.source_value_key, '')
    and (source_values.source_value_key is null) = (normalized_inputs.source_value_key is null)
), normalized as (
  select
    product_id,
    domain_key,
    domain_label,
    value_key,
    case
      when value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'
        then upper(value_key)
      when value_key ~ '^w[0-9]{2,3}-l[0-9]{2,3}$'
        then 'W' || substring(value_key from '^w([0-9]{2,3})') || ' × L'
          || substring(value_key from '-l([0-9]{2,3})$')
      when value_key = 'one-size' then 'Vienas dydis'
      when value_key is null then null
      when had_known_description then value_key
      when value_key <> original_key then value_key
      else coalesce(nullif(trim(value_override->>'label'), ''), source_display_label)
    end as display_label,
    sort_order
  from normalized_keys
), expanded as (
  select
    normalized.*,
    component.value_key as facet_value_key
  from normalized
  cross join lateral unnest(
    case
      when normalized.domain_key in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear', 'gloves', 'headwear', 'socks')
        and normalized.value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)-(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'
        then string_to_array(normalized.value_key, '-')
      else array[normalized.value_key]
    end
  ) as component(value_key)
)
select
  product_id,
  domain_key,
  domain_label,
  facet_value_key as value_key,
  case when facet_value_key <> value_key then upper(facet_value_key) else display_label end as display_label,
  domain_key || ':' || facet_value_key as token,
  public.catalog_effective_size_sort_order(facet_value_key) as sort_order
from expanded
where facet_value_key is not null;

commit;
