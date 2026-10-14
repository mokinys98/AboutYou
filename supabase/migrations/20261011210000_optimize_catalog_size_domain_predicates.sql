-- Keep the existing catalog_size_facets_read materialized view and its schema
-- intact, while replacing regex predicates in its source classifier with
-- literal substring checks. This changes no MV data until its next refresh.
-- It does not start a refresh or modify the cron job.
begin;
set local statement_timeout = '5s';
set local lock_timeout = '3s';

do $$
declare
  v_owner text;
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  select pg_get_userbyid(p.proowner)
  into v_owner
  from pg_proc p
  where p.oid = 'public.catalog_size_domain(text[],text[],text)'::regprocedure;

  if v_owner is distinct from current_user then
    raise exception 'catalog_size_domain is owned by %, not %', v_owner, current_user;
  end if;

  if md5(pg_get_functiondef('public.catalog_size_domain(text[],text[],text)'::regprocedure))
       <> '126e94ff3bb480bead8470768d63795a' then
    raise exception 'Unexpected catalog_size_domain definition; inspect VPS before applying';
  end if;
end;
$$;

create or replace function public.catalog_size_domain(
  p_category_paths text[],
  p_category_names text[],
  p_product_name text
) returns text
language sql immutable
set search_path = public, pg_temp as $$
  with source_text as (
    select lower(array_to_string(coalesce(p_category_paths, '{}') || coalesce(p_category_names, '{}'), ' ')
      || ' ' || coalesce(p_product_name, '')) as value
  )
  select case
    when position('kojin' in value) > 0 then 'socks'
    when position('apatin' in value) > 0 then 'underwear'
    when position('bat' in value) > 0 or position('ked' in value) > 0 then 'shoes'
    when position('keln' in value) > 0 or position('džins' in value) > 0 then 'trousers'
    when position('marškin' in value) > 0 then 'shirts'
    when position('švark' in value) > 0 or position('kostium' in value) > 0 then 'suitwear'
    when position('maudym' in value) > 0 or position('bikin' in value) > 0 or position('plaukimo' in value) > 0 then 'swimwear'
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
  end
  from source_text;
$$;

commit;
