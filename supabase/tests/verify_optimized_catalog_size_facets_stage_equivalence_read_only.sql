-- Run after the optimized stage is populated. This compares the full candidate
-- SELECT to the staged rows in both directions. Expected: source_rows =
-- stage_rows and differing_rows = 0. Read-only; it may approach the SQL
-- Editor's upstream timeout. Do not increase the timeout or rerun on timeout
-- until the stage population state has been inspected.
begin read only;
set local statement_timeout = '28s';
set local lock_timeout = '2s';

with source_texts as materialized (
  select
    i.id as product_id,
    i.sizes,
    i.other_sizes,
    lower(array_to_string(
      coalesce(i.category_paths, '{}') || coalesce(i.category_names, '{}'), ' '
    ) || ' ' || coalesce(i.name, '')) as value
  from public.catalog_items_read i
), item_inputs as materialized (
  select
    product_id,
    sizes,
    other_sizes,
    case
      when position('kojin' in value) > 0 then 'socks'
      when position('apatin' in value) > 0 then 'underwear'
      when position('bat' in value) > 0 or position('ked' in value) > 0 then 'shoes'
      when position('keln' in value) > 0 or position('džins' in value) > 0 then 'trousers'
      when position('marškin' in value) > 0 then 'shirts'
      when position('švark' in value) > 0 or position('kostium' in value) > 0 then 'suitwear'
      when position('maudym' in value) > 0 or position('bikin' in value) > 0
        or position('plaukimo' in value) > 0 then 'swimwear'
      when position('dirž' in value) > 0 then 'belts'
      when position('kepur' in value) > 0 or position('skryb' in value) > 0 then 'headwear'
      when position('piršt' in value) > 0 then 'gloves'
      when position('akin' in value) > 0 then 'eyewear'
      when position('žied' in value) > 0 then 'rings'
      when position('apyrank' in value) > 0 then 'bracelets'
      when position('krepš' in value) > 0 or position('kuprin' in value) > 0 then 'bags'
      when position('pinigin' in value) > 0 or position('kosmetin' in value) > 0 then 'wallets'
      when position('aksesuar' in value) > 0 then 'accessories'
      when position('drabuž' in value) > 0 then 'clothing'
      else 'other'
    end as domain_key
  from source_texts
), option_values as (
  select d.product_id, d.domain_key, o.label as value, o.size_group as second_dimension
  from item_inputs d
  join public.product_size_options o on o.product_id = d.product_id and o.selectable

  union all

  select d.product_id, d.domain_key, v.value, null::text
  from item_inputs d
  cross join lateral unnest(coalesce(d.sizes, '{}') || coalesce(d.other_sizes, '{}')) as v(value)
  where not exists (
    select 1 from public.product_size_options o where o.product_id = d.product_id
  )
), normalized as (
  select distinct
    product_id,
    domain_key,
    public.catalog_size_domain_label(domain_key) as domain_label,
    public.catalog_size_value_key(
      value || case
        when nullif(trim(second_dimension), '') is not null then '-' || trim(second_dimension)
        else ''
      end
    ) as value_key,
    case
      when nullif(trim(second_dimension), '') is not null
        then trim(value) || ' / ' || trim(second_dimension)
      else trim(value)
    end as display_label,
    public.catalog_size_sort_order(value) as sort_order
  from option_values
  where trim(coalesce(value, '')) <> ''
), source_rows as materialized (
  select
    product_id,
    domain_key,
    domain_label,
    value_key,
    display_label,
    domain_key || ':' || value_key as token,
    sort_order
  from normalized
), source_only as (
  select * from source_rows
  except all
  select product_id, domain_key, domain_label, value_key, display_label, token, sort_order
  from public.catalog_size_facets_read_optimized_stage
), stage_only as (
  select product_id, domain_key, domain_label, value_key, display_label, token, sort_order
  from public.catalog_size_facets_read_optimized_stage
  except all
  select * from source_rows
)
select
  (select count(*) from source_rows) as source_rows,
  (select count(*) from public.catalog_size_facets_read_optimized_stage) as stage_rows,
  (select count(*) from source_only) + (select count(*) from stage_only) as differing_rows,
  (select count(*) from source_only) as source_only_rows,
  (select count(*) from stage_only) as stage_only_rows;

rollback;
