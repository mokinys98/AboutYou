-- Do not infer phone-case compatibility from product names.
-- Words such as GALAXY may describe a clothing product, for example
-- HUGO boxer briefs named GALAXY. Compatibility values are not body sizes.

update public.catalog_size_classification_overrides
set size_domain = 'other',
    note = case
      when nullif(trim(note), '') is null then 'Perkelta iš device_cases: telefono modelis nėra dydžio grupė.'
      else note || ' Perkelta iš device_cases: telefono modelis nėra dydžio grupė.'
    end,
    updated_at = now()
where size_domain = 'device_cases';

alter table public.catalog_size_classification_overrides
  drop constraint if exists catalog_size_classification_overrides_size_domain_check;

alter table public.catalog_size_classification_overrides
  add constraint catalog_size_classification_overrides_size_domain_check check (size_domain in (
    'clothing', 'shirts', 'trousers', 'suitwear', 'underwear', 'swimwear',
    'socks', 'shoes', 'belts', 'headwear', 'gloves', 'eyewear', 'rings',
    'bracelets', 'bags', 'wallets', 'accessories', 'other'
  ));

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

create or replace function public.catalog_size_domain_label(p_domain text)
returns text
language sql immutable
set search_path = public, pg_temp as $$
  select case p_domain
    when 'clothing' then 'Drabužiai'
    when 'shirts' then 'Marškiniai'
    when 'trousers' then 'Kelnės ir džinsai'
    when 'suitwear' then 'Kostiumai ir švarkai'
    when 'underwear' then 'Apatiniai'
    when 'swimwear' then 'Maudymosi drabužiai'
    when 'socks' then 'Kojinės'
    when 'shoes' then 'Batai'
    when 'belts' then 'Diržai'
    when 'headwear' then 'Kepurės ir skrybėlės'
    when 'gloves' then 'Pirštinės'
    when 'eyewear' then 'Akiniai'
    when 'rings' then 'Žiedai'
    when 'bracelets' then 'Apyrankės'
    when 'bags' then 'Krepšiai ir kuprinės'
    when 'wallets' then 'Piniginės ir kosmetinės'
    when 'accessories' then 'Kiti aksesuarai'
    else 'Kita'
  end;
$$;

refresh materialized view public.catalog_size_facets_read;
delete from public.catalog_facets_cache;
notify pgrst, 'reload schema';
