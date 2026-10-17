-- VPS Supabase SQL Editor handoff. This refreshes only the shadow stage MV,
-- then compares it with its source in the same REPEATABLE READ snapshot.
-- It does not change the production views or cron. Run only while the refresh
-- cron is paused. Expected result: differing_rows=0. If the SQL Editor times
-- out, inspect stage_populated and do not rerun blindly.
begin;
set transaction isolation level repeatable read;
set local statement_timeout = '90s';
set local lock_timeout = '3s';

do $$
declare
  v_jobs integer;
  v_all_paused boolean;
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
      and r.status = 'running'
      and r.end_time is null
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
    raise exception 'A catalog refresh or stage lock is still held';
  end if;

  if not exists (
    select 1 from pg_class c
    where c.oid = 'public.catalog_size_facets_read_optimized_stage'::regclass
      and c.relkind = 'm'
      and c.relispopulated
      and pg_get_userbyid(c.relowner) = current_user
  ) then
    raise exception 'Expected a populated stage materialized view owned by postgres';
  end if;
end;
$$;

refresh materialized view public.catalog_size_facets_read_optimized_stage;

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
select
  transaction_timestamp() as snapshot_started_at,
  (select requested_version from public.catalog_read_model_refresh_state where singleton) as requested_version,
  (select completed_version from public.catalog_read_model_refresh_state where singleton) as completed_version,
  (select count(*) from source_rows) as source_rows,
  (select count(*) from stage_rows) as stage_rows,
  (select count(*) from source_only) + (select count(*) from stage_only) as differing_rows,
  (select count(*) from source_only) as source_only_rows,
  (select count(*) from stage_only) as stage_only_rows;

commit;
