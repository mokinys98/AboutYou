-- Brand and search targets do not provide an authoritative target category.
-- Backfill only products that still have no category, using the same conservative
-- name and product-type rules as the sync worker fallback classifier.
insert into public.categories(slug, name)
select 'category-' || md5(lower(inferred.name)), inferred.name
from (values
  ('Batai'), ('Aksesuarai'), ('Marškinėliai'), ('Džinsai'), ('Apatiniai'),
  ('Striukės'), ('Marškiniai'), ('Treningo dalys'), ('Maudymosi drabužiai'),
  ('Megztiniai'), ('Kostiumai ir švarkai'), ('Paltai'), ('Kelnės')
) inferred(name)
where not exists (
  select 1
  from public.categories existing
  where lower(existing.name) = lower(inferred.name)
)
on conflict (slug) do update set name = excluded.name;

with uncategorized_products as (
  select
    p.id,
    lower(concat_ws(' ', p.name, array_to_string(coalesce(p.product_types, '{}'::text[]), ' '))) as classification_text
  from public.products p
  where not exists (
    select 1
    from public.product_categories pc
    where pc.product_id = p.id
  )
), inferred_categories as (
  select product_id, category_name
  from (
    select
      up.id as product_id,
      rule.category_name,
      row_number() over (partition by up.id order by rule.priority) as category_rank
    from uncategorized_products up
    join (values
      (1, 'Batai', '(batai|batų|sportbač|šlepet|loafer|sandal|aulin|espadril|mokasin|chukka|chelsea)'),
      (2, 'Aksesuarai', '(^|[[:space:]])dirž(as|ai)($|[[:space:]])|kepur|rankin|akini|pirštin'),
      (3, 'Marškinėliai', 'marškinėl|polo|berankov'),
      (4, 'Džinsai', 'džins'),
      (5, 'Apatiniai', 'apatin|kojin|naktin|chalatas|trumpik|pižam'),
      (6, 'Striukės', 'striuk|parka|bomber|liemenė'),
      (7, 'Marškiniai', 'marškiniai'),
      (8, 'Treningo dalys', 'džemper|trening|sportinės kelnės'),
      (9, 'Maudymosi drabužiai', 'maudym|glaud'),
      (10, 'Megztiniai', 'megztin|kardigan'),
      (11, 'Kostiumai ir švarkai', 'kostium|švark'),
      (12, 'Paltai', 'palt|lietpalt'),
      (13, 'Kelnės', 'keln|šort')
    ) rule(priority, category_name, pattern)
      on up.classification_text ~ rule.pattern
  ) ranked
  where category_rank <= 2
)
insert into public.product_categories(product_id, category_id)
select inferred.product_id, category.id
from inferred_categories inferred
join lateral (
  select id
  from public.categories
  where lower(name) = lower(inferred.category_name)
  order by id
  limit 1
) category on true
on conflict do nothing;
