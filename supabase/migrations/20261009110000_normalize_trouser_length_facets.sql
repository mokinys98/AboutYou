-- Normalize trouser size labels whose source labels encode inseam or length
-- descriptions with hyphens. Keep the numeric waist/inseam pair when present;
-- discard only descriptive length words when no numeric inseam is supplied.
begin;

create or replace function public.catalog_normalize_trouser_size_value(
  p_value text
) returns text
language sql immutable
set search_path = public, pg_temp as $$
  with source as (
    select translate(lower(trim(coalesce(p_value, ''))), '–—−‐‑', '-----') as value
  ), parsed as (
    select value,
      regexp_match(value,
        '^(?:w[[:space:]]*)?([0-9]{2,3})[[:space:]]*[x×-][[:space:]]*([0-9]{2,3})(?:[[:space:]]*-[[:space:]]*\2)*(?:[[:space:]-]*/[[:space:]-]*(?:l[[:space:]]*)?\2)?$') as numeric_pair,
      regexp_match(value,
        '^(?:w[[:space:]]*)?([0-9]{2,3})[[:space:]]*[x×-][[:space:]]*([0-9]{2,3})[[:space:]-]*-[[:space:]-]*(?:įprastas[[:space:]-]+ilgis|normalus[[:space:]-]+ilgis|trumpas|labai[[:space:]-]+trumpas|ilgas|labai[[:space:]-]+ilgas|regular(?:[[:space:]-]+length)?|short|long|extra[[:space:]-]+long|tall)(?:[[:space:]-]*/.*)?$') as pair_with_length_label,
      regexp_match(value,
        '^(?:w[[:space:]]*)?([0-9]{2,3})[[:space:]]*[x×-][[:space:]]*(?:įprastas[[:space:]-]+ilgis|normalus[[:space:]-]+ilgis|trumpas|labai[[:space:]-]+trumpas|ilgas|labai[[:space:]-]+ilgas|regular(?:[[:space:]-]+length)?|short|long|extra[[:space:]-]+long|tall|slim)(?:[[:space:]-]*/.*)?$') as waist_with_length_label,
      regexp_match(value,
        '^(?:ilgis|length)[[:space:]-]*([0-9]{2,3})(?:[[:space:]-]*/.*)?$') as length_prefix_waist
    from source
  )
  select case
    when numeric_pair is not null
      then 'w' || (numeric_pair)[1] || '-l' || (numeric_pair)[2]
    when pair_with_length_label is not null
      then 'w' || (pair_with_length_label)[1] || '-l' || (pair_with_length_label)[2]
    when waist_with_length_label is not null
      then (waist_with_length_label)[1]
    when length_prefix_waist is not null
      then (length_prefix_waist)[1]
    else null
  end
  from parsed;
$$;

revoke all on function public.catalog_normalize_trouser_size_value(text)
  from public, anon, authenticated;
grant execute on function public.catalog_normalize_trouser_size_value(text)
  to service_role;

create or replace view public.catalog_size_facets_read_effective as
with source_values as (
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
), normalized_keys as (
  select
    product_id,
    domain_key,
    public.catalog_size_domain_label(domain_key) as domain_label,
    coalesce(
      case when domain_key = 'trousers'
        then public.catalog_normalize_trouser_size_value(normalization_input)
      end,
      public.catalog_effective_size_value_key(domain_key, normalization_input)
    ) as value_key,
    public.catalog_effective_size_value_key(source_value_key) as original_key,
    source_display_label,
    value_override,
    sort_order
  from source_values
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
      when value_key is null then null
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
      when normalized.value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)-(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'
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

create or replace function public.catalog_canonical_size_token(p_token text)
returns text
language sql immutable
set search_path = public, pg_temp as $$
  select case
    when position(':' in coalesce(p_token, '')) = 0 then p_token
    else split_part(p_token, ':', 1) || ':' || coalesce(
      case when split_part(p_token, ':', 1) = 'trousers'
        then public.catalog_normalize_trouser_size_value(
          substr(p_token, position(':' in p_token) + 1)
        )
      end,
      public.catalog_effective_size_value_key(
        split_part(p_token, ':', 1),
        substr(p_token, position(':' in p_token) + 1)
      ),
      substr(p_token, position(':' in p_token) + 1)
    )
  end;
$$;

create or replace function public.catalog_canonical_size_tokens(p_token text)
returns text[]
language plpgsql immutable
set search_path = public, pg_temp as $$
begin
  if position(':' in coalesce(p_token, '')) = 0 then
    return array[p_token];
  end if;

  return (
    with parts as (
      select split_part(p_token, ':', 1) as domain_key,
        substr(p_token, position(':' in p_token) + 1) as raw_value,
        coalesce(
          case when split_part(p_token, ':', 1) = 'trousers'
            then public.catalog_normalize_trouser_size_value(
              substr(p_token, position(':' in p_token) + 1)
            )
          end,
          public.catalog_effective_size_value_key(
            split_part(p_token, ':', 1),
            substr(p_token, position(':' in p_token) + 1)
          )
        ) as value_key
    )
    select case
      when domain_key = 'trousers' and raw_value ~ '^[0-9]{2,3}-[0-9]{2,3}$'
        then array[
          domain_key || ':' || raw_value,
          domain_key || ':' || value_key
        ]
      when domain_key in ('clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear')
        and value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)-(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'
        then array[
          domain_key || ':' || split_part(value_key, '-', 1),
          domain_key || ':' || split_part(value_key, '-', 2)
        ]
      else array[public.catalog_canonical_size_token(p_token)]
    end
    from parts
  );
end;
$$;

revoke all on function public.catalog_canonical_size_token(text)
  from public, anon, authenticated;
grant execute on function public.catalog_canonical_size_token(text)
  to service_role;
revoke all on function public.catalog_canonical_size_tokens(text)
  from public, anon, authenticated;
grant execute on function public.catalog_canonical_size_tokens(text)
  to service_role;

notify pgrst, 'reload schema';
commit;
