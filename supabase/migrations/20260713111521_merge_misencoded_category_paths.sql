with path_map(source_path, target_path) as (values
  ('vyrams>aksesuarai>akiniai nuo saulä—s', 'vyrams>aksesuarai>akiniai nuo saulės'),
  ('vyrams>aksesuarai>kepurä—s', 'vyrams>aksesuarai>kepurės'),
  ('vyrams>aksesuarai>kepurä—s>megztos kepurä—s', 'vyrams>aksesuarai>kepurės>megztos kepurės'),
  ('vyrams>aksesuarai>kepurä—s>skrybä—lä—s', 'vyrams>aksesuarai>kepurės>skrybėlės'),
  ('vyrams>aksesuarai>juvelyriniai dirbiniai>apyrankä—s', 'vyrams>aksesuarai>juvelyriniai dirbiniai>apyrankės'),
  ('vyrams>aksesuarai>å alikai ir å¡aliai', 'vyrams>aksesuarai>šalikai ir šaliai'),
  ('vyrams>aksesuarai>laikrodå¾iai', 'vyrams>aksesuarai>laikrodžiai')
)
insert into public.product_categories(product_id, category_id)
select link.product_id, target.id
from path_map mapping
join public.categories source on source.path = mapping.source_path
join public.categories target on target.path = mapping.target_path
join public.product_categories link on link.category_id = source.id
on conflict do nothing;

delete from public.categories
where path in (
  'vyrams>aksesuarai>akiniai nuo saulä—s',
  'vyrams>aksesuarai>kepurä—s',
  'vyrams>aksesuarai>kepurä—s>megztos kepurä—s',
  'vyrams>aksesuarai>kepurä—s>skrybä—lä—s',
  'vyrams>aksesuarai>juvelyriniai dirbiniai>apyrankä—s',
  'vyrams>aksesuarai>å alikai ir å¡aliai',
  'vyrams>aksesuarai>laikrodå¾iai'
);
