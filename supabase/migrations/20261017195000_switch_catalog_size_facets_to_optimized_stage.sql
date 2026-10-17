-- Atomic, reversible switch from the old catalog size MV to the optimized
-- stage. The transaction refreshes the populated shadow stage, rechecks exact
-- source/stage equality in the same snapshot, then changes the relation names.
-- The old MV is retained as a locked-down rollback backup; cron remains paused.
begin;
set transaction isolation level repeatable read;
set local statement_timeout = '120s';
set local lock_timeout = '3s';
set local search_path = public, pg_temp;

do $$
declare
  v_jobs integer;
  v_all_paused boolean;
  v_view_owner text;
  v_view_definition text;
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  select count(*), coalesce(bool_and(not j.active), false)
  into v_jobs, v_all_paused
  from cron.job j
  where j.jobname = 'catalog-read-model-refresh'
    and j.schedule = '*/5 * * * *'
    and j.command ilike '%process_catalog_items_read_refresh()%';
  if v_jobs <> 1 or not v_all_paused then
    raise exception 'Expected exactly one paused catalog refresh job; found %, all_paused=%',
      v_jobs, v_all_paused;
  end if;

  if exists (
    select 1 from cron.job_run_details r
    join cron.job j on j.jobid = r.jobid
    where j.jobname = 'catalog-read-model-refresh'
      and r.status = 'running' and r.end_time is null
  ) then
    raise exception 'A catalog refresh cron run is still active';
  end if;

  if exists (
    select 1 from pg_locks l
    where (l.locktype = 'advisory'
      and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted)
      or (l.relation in (
        'public.catalog_items_read'::regclass,
        'public.catalog_item_facet_values_read'::regclass,
        'public.catalog_size_facets_read'::regclass,
        'public.catalog_effective_size_membership_read'::regclass,
        'public.catalog_size_facets_read_optimized_stage'::regclass
      ) and l.mode in ('ExclusiveLock', 'AccessExclusiveLock') and l.granted)
  ) then
    raise exception 'A catalog refresh lock is still held';
  end if;

  if to_regclass('public.catalog_size_facets_read_backup_20261017') is not null then
    raise exception 'Rollback backup name already exists; inspect before switching';
  end if;

  if not exists (
    select 1 from pg_class c
    where c.oid = 'public.catalog_size_facets_read'::regclass
      and c.relkind = 'm' and c.relispopulated
      and pg_get_userbyid(c.relowner) = current_user
  ) then
    raise exception 'Expected a populated production size MV owned by postgres';
  end if;

  if not exists (
    select 1 from pg_class c
    where c.oid = 'public.catalog_size_facets_read_optimized_stage'::regclass
      and c.relkind = 'm' and c.relispopulated
      and pg_get_userbyid(c.relowner) = current_user
  ) then
    raise exception 'Expected a populated optimized stage owned by postgres';
  end if;

  if (select count(*) from pg_index i
      join pg_class ic on ic.oid = i.indexrelid
      where i.indrelid = 'public.catalog_size_facets_read_optimized_stage'::regclass
        and ic.relname in (
          'catalog_size_facets_read_optimized_stage_unique_idx',
          'catalog_size_facets_read_optimized_stage_domain_idx',
          'catalog_size_facets_read_optimized_stage_token_idx'
        ) and i.indisvalid and i.indisready) <> 3
      or not exists (
        select 1 from pg_index i join pg_class ic on ic.oid = i.indexrelid
        where i.indrelid = 'public.catalog_size_facets_read_optimized_stage'::regclass
          and ic.relname = 'catalog_size_facets_read_optimized_stage_unique_idx'
          and i.indisunique
      ) then
    raise exception 'Expected all three valid stage indexes including the unique refresh index';
  end if;

  if has_table_privilege('anon', 'public.catalog_size_facets_read_optimized_stage', 'SELECT')
     or has_table_privilege('authenticated', 'public.catalog_size_facets_read_optimized_stage', 'SELECT')
     or not has_table_privilege('service_role', 'public.catalog_size_facets_read_optimized_stage', 'SELECT') then
    raise exception 'Unexpected optimized-stage SELECT ACLs';
  end if;

  select pg_get_userbyid(c.relowner), pg_get_viewdef(c.oid, true)
  into v_view_owner, v_view_definition
  from pg_class c
  where c.oid = 'public.catalog_size_facets_read_effective'::regclass
    and c.relkind = 'v';
  if v_view_owner <> current_user
     or md5(v_view_definition) <> '88c25cab7939592911a1f1a045b772e9'
     or position('source_values AS MATERIALIZED' in v_view_definition) = 0
     or position('normalized_components AS MATERIALIZED' in v_view_definition) = 0
     or position('catalog_size_facets_read sf' in v_view_definition) = 0 then
    raise exception 'Effective size view changed since read-only inspection; inspect before switching';
  end if;

  if exists (
    select attnum, attname, atttypid, atttypmod
    from pg_attribute
    where attrelid = 'public.catalog_size_facets_read'::regclass
      and attnum > 0 and not attisdropped
    except
    select attnum, attname, atttypid, atttypmod
    from pg_attribute
    where attrelid = 'public.catalog_size_facets_read_optimized_stage'::regclass
      and attnum > 0 and not attisdropped
  ) or exists (
    select attnum, attname, atttypid, atttypmod
    from pg_attribute
    where attrelid = 'public.catalog_size_facets_read_optimized_stage'::regclass
      and attnum > 0 and not attisdropped
    except
    select attnum, attname, atttypid, atttypmod
    from pg_attribute
    where attrelid = 'public.catalog_size_facets_read'::regclass
      and attnum > 0 and not attisdropped
  ) then
    raise exception 'Production and optimized stage column layouts differ';
  end if;

end;
$$;

-- Rebuild the isolated shadow stage from the same REPEATABLE READ snapshot
-- that the equality guard below will inspect. This closes the observed window
-- where product_size_options changed after the separately measured stage run.
refresh materialized view public.catalog_size_facets_read_optimized_stage;

do $$
declare
  v_source_rows bigint;
  v_stage_rows bigint;
  v_differing_rows bigint;
  v_source_version bigint;
  v_completed_version bigint;
begin
  select requested_version, completed_version
  into v_source_version, v_completed_version
  from public.catalog_read_model_refresh_state where singleton;

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
), stage_rows as materialized (
  select product_id, domain_key, domain_label, value_key, display_label, token, sort_order
  from public.catalog_size_facets_read_optimized_stage
), source_only as (
  select * from source_rows
  except all
  select product_id, domain_key, domain_label, value_key, display_label, token, sort_order
  from stage_rows
), stage_only as (
  select product_id, domain_key, domain_label, value_key, display_label, token, sort_order
  from stage_rows
  except all
  select * from source_rows
)
  select (select count(*) from source_rows),
         (select count(*) from stage_rows),
         (select count(*) from source_only) + (select count(*) from stage_only)
  into v_source_rows, v_stage_rows, v_differing_rows;

  if v_differing_rows <> 0 or v_source_rows <> v_stage_rows then
    raise exception 'Stage/source mismatch in cutover snapshot: source %, stage %, differences %',
      v_source_rows, v_stage_rows, v_differing_rows;
  end if;

  raise log 'catalog_size_stage_cutover snapshot_source_rows=% snapshot_stage_rows=% differing_rows=% requested_version=% completed_version=%',
    v_source_rows, v_stage_rows, v_differing_rows, v_source_version, v_completed_version;
end;
$$;

alter materialized view public.catalog_size_facets_read
  rename to catalog_size_facets_read_backup_20261017;

alter materialized view public.catalog_size_facets_read_optimized_stage
  rename to catalog_size_facets_read;

revoke all on table public.catalog_size_facets_read_backup_20261017
  from public, anon, authenticated, service_role;

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

comment on materialized view public.catalog_size_facets_read is
  'Optimized catalog size facets read model; switched from the verified shadow stage on 2026-10-17.';
comment on materialized view public.catalog_size_facets_read_backup_20261017 is
  'Rollback copy of catalog_size_facets_read retained after the 2026-10-17 optimized stage cutover.';

analyze public.catalog_size_facets_read;

commit;
