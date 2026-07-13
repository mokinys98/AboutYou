create index if not exists brand_tiers_updated_by_idx
  on public.brand_tiers(updated_by) where updated_by is not null;

with candidates as materialized (
  select p.id,
    case
      when value ~ 'akiniai nuo saul' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Akiniai nuo saulės')
      when value ~ 'megzta kepur' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Kepurės', 'Megztos kepurės')
      when value ~ 'skrybėl' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Kepurės', 'Skrybėlės')
      when value ~ 'kuprinė' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Krepšiai ir kuprinės', 'Kuprinės')
      when value ~ 'tualeto reikmenų|kosmetikos krepš' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Piniginės ir kosmetinės')
      when value ~ 'pirkinių krepš|sportinis krepš|krepšys|rankinė' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Krepšiai ir kuprinės', 'Krepšiai')
      when value ~ 'laikrodis' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Laikrodžiai')
      when value ~ 'apyrank' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Juvelyriniai dirbiniai', 'Apyrankės')
      when value ~ 'grandinėl' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Juvelyriniai dirbiniai', 'Grandinėlės')
      when value ~ 'auskar|žiedas' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Juvelyriniai dirbiniai')
      when value ~ 'šalik|skara' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Šalikai ir šaliai')
      when value ~ 'raktų laikikl' then jsonb_build_array('Vyrams', 'Aksesuarai')
      when value ~ 'sportbačiai be auliuko' then jsonb_build_array('Vyrams', 'Batai', 'Sportbačiai', 'Sportbačiai žemu auliuku')
      when value ~ 'šlepet' then jsonb_build_array('Vyrams', 'Batai', 'Atviri batai', 'Šlepetės')
      when value ~ 'auliniai batai' then jsonb_build_array('Vyrams', 'Batai', 'Batai ir auliniai batai', 'Auliniai batai')
      when value ~ 'sportinės kojinės|kojinės' then jsonb_build_array('Vyrams', 'Drabužiai', 'Apatiniai', 'Kojinės')
      else null
    end as target_path
  from public.products p
  cross join lateral (
    values (lower(concat_ws(' ', p.name, array_to_string(coalesce(p.product_types, '{}'), ' '))))
  ) classification(value)
  where p.active and p.category_path_updated_at is null
)
select public.record_product_category_path(id, target_path, false)
from candidates
where target_path is not null;

-- A Premium sync target is a merchandising collection, not a taxonomy root.
-- Any non-authoritative product still linked to it is at least an accessory.
with premium_fallback as materialized (
  select distinct p.id
  from public.products p
  join public.product_categories link on link.product_id = p.id
  join public.categories category on category.id = link.category_id
  where p.active and p.category_path_updated_at is null and category.path = 'vyrams>premium'
)
select public.record_product_category_path(
  id, jsonb_build_array('Vyrams', 'Aksesuarai'), false
)
from premium_fallback;

select public.record_product_category_path(
  p.id, jsonb_build_array('Vyrams', 'Aksesuarai', 'Kepurės', 'Skrybėlės'), false
)
from public.products p
where p.active and p.category_path_updated_at is null
  and not exists (
    select 1 from public.product_categories link where link.product_id = p.id
  );

do $$
begin
  if exists (
    select 1
    from public.products p
    join public.product_categories link on link.product_id = p.id
    join public.categories category on category.id = link.category_id
    where p.active and p.category_path_updated_at is null and category.path = 'vyrams>premium'
  ) then
    raise exception 'Premium fallback category links remain after audit';
  end if;
  if exists (
    select 1 from public.products p
    where p.active and not exists (
      select 1 from public.product_categories link where link.product_id = p.id
    )
  ) then
    raise exception 'Active uncategorized products remain after audit';
  end if;
end $$;
