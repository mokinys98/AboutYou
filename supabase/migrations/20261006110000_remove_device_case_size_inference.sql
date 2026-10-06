-- A product name such as "Galaxy 8" identifies running shoes, not a phone case.
-- The existing device_cases branch classifies these products before their shoe
-- category is considered. The next naturally requested catalog refresh rebuilds
-- effective size membership and the root facet cache with this definition.
begin;

do $$
begin
  if not exists (
    select 1
    from pg_proc p
    where p.oid = 'public.catalog_size_domain(text[],text[],text)'::regprocedure
      and pg_get_userbyid(p.proowner) = current_user
  ) then
    raise exception 'catalog_size_domain owner differs from SQL Editor user; inspect before applying';
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
    when value ~ '(kojin)' then 'socks'
    when value ~ '(apatin)' then 'underwear'
    when value ~ '(bat|ked)' then 'shoes'
    when value ~ '(keln|džins)' then 'trousers'
    when value ~ '(marškin)' then 'shirts'
    when value ~ '(švark|kostium)' then 'suitwear'
    when value ~ '(maudym|bikin|plaukimo)' then 'swimwear'
    when value ~ '(dirž)' then 'belts'
    when value ~ '(kepur|skryb)' then 'headwear'
    when value ~ '(piršt)' then 'gloves'
    when value ~ '(akin)' then 'eyewear'
    when value ~ '(žied)' then 'rings'
    when value ~ '(apyrank)' then 'bracelets'
    when value ~ '(krepš|kuprin)' then 'bags'
    when value ~ '(pinigin|kosmetin)' then 'wallets'
    when value ~ '(aksesuar)' then 'accessories'
    when value ~ '(drabuž)' then 'clothing'
    else 'other'
  end
  from source_text;
$$;

commit;
