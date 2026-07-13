do $$
declare
  product record;
  target_path jsonb;
begin
  for product in
    select p.id,
      lower(concat_ws(' ', p.name, array_to_string(coalesce(p.product_types, '{}'), ' '))) as value
    from public.products p
    where p.active and p.category_path_updated_at is null
  loop
    target_path := case
      when product.value ~ 'akiniai nuo saul' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Akiniai nuo saulės')
      when product.value ~ 'megzta kepur' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Kepurės', 'Megztos kepurės')
      when product.value ~ 'skrybėl' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Kepurės', 'Skrybėlės')
      when product.value ~ 'kuprinė' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Krepšiai ir kuprinės', 'Kuprinės')
      when product.value ~ 'tualeto reikmenų|kosmetikos krepš' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Piniginės ir kosmetinės')
      when product.value ~ 'pirkinių krepš|sportinis krepš|krepšys|rankinė' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Krepšiai ir kuprinės', 'Krepšiai')
      when product.value ~ 'laikrodis' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Laikrodžiai')
      when product.value ~ 'apyrank' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Juvelyriniai dirbiniai', 'Apyrankės')
      when product.value ~ 'grandinėl' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Juvelyriniai dirbiniai', 'Grandinėlės')
      when product.value ~ 'auskar|žiedas' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Juvelyriniai dirbiniai')
      when product.value ~ 'šalik|skara' then jsonb_build_array('Vyrams', 'Aksesuarai', 'Šalikai ir šaliai')
      when product.value ~ 'raktų laikikl' then jsonb_build_array('Vyrams', 'Aksesuarai')
      when product.value ~ 'sportbačiai be auliuko' then jsonb_build_array('Vyrams', 'Batai', 'Sportbačiai', 'Sportbačiai žemu auliuku')
      when product.value ~ 'šlepet' then jsonb_build_array('Vyrams', 'Batai', 'Atviri batai', 'Šlepetės')
      when product.value ~ 'auliniai batai' then jsonb_build_array('Vyrams', 'Batai', 'Batai ir auliniai batai', 'Auliniai batai')
      when product.value ~ 'sportinės kojinės|kojinės' then jsonb_build_array('Vyrams', 'Drabužiai', 'Apatiniai', 'Kojinės')
      else null
    end;
    if target_path is not null then
      perform public.record_product_category_path(product.id, target_path, false);
    end if;
  end loop;
end $$;
