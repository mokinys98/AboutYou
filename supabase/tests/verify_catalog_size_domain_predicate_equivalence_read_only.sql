-- Before the proposed predicate change, compare its literal checks with the
-- installed catalog_size_domain() for every current catalog item.
-- Expected: compared_rows > 0 and mismatched_rows = 0. Cron stays paused.
begin read only;
set local statement_timeout = '45s';
set local lock_timeout = '2s';

with inputs as materialized (
  select
    i.category_paths,
    i.category_names,
    i.name,
    lower(array_to_string(
      coalesce(i.category_paths, '{}') || coalesce(i.category_names, '{}'), ' '
    ) || ' ' || coalesce(i.name, '')) as value
  from public.catalog_items_read i
), compared as (
  select
    public.catalog_size_domain(category_paths, category_names, name) as installed_domain,
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
      when position('pinigin' in value) > 0 or position('kosmetin' in value) > 0
        then 'wallets'
      when position('aksesuar' in value) > 0 then 'accessories'
      when position('drabuž' in value) > 0 then 'clothing'
      else 'other'
    end as proposed_domain
  from inputs
)
select
  count(*) as compared_rows,
  count(*) filter (
    where installed_domain is distinct from proposed_domain
  ) as mismatched_rows
from compared;

rollback;
