-- Complete the canonical ABOUT YOU menu. The first nested-tree backfill only
-- contained Drabužiai, Batai and Sportas, while the source menu also contains
-- Aksesuarai and Streetwear.
do $$
declare
  taxonomy jsonb := $taxonomy$
  {
    "Drabužiai": {
      "Marškinėliai": ["Polo marškinėliai", "Laisvalaikio marškinėliai", "Marškinėlių komplektai", "Berankoviai marškinėliai", "Marškinėliai ilgomis rankovėmis"],
      "Kelnės": ["Šortai", "„Chino“ stiliaus kelnės", "Sportinės kelnės", "Kasdienės kelnės", "„Cargo“ stiliaus kelnės"],
      "Apatiniai": ["Apatinės kelnės", "Kojinės", "Apatiniai marškinėliai", "Naktiniai drabužiai", "Vonios chalatai"],
      "Džinsai": ["Džinsiniai šortai", "Tiesūs džinsai", "Siauri prigludę džinsai", "Laisvo kirpimo džinsai", "Siauri džinsai", "Siaurėjantys džinsai"],
      "Striukės": ["Odinės striukės", "Liemenės", "Džinsiniai švarkeliai ir striukės", "Demisezoninės striukės", "Žieminės striukės", "Dygsniuotos striukės", "„Bomber“ stiliaus striukės", "Parka striukės", "Laisvalaikio striukės", "Striukės nuo lietaus", "Pūkinės striukės"],
      "Marškiniai": ["Kasdieniniai marškiniai", "Dalykinio stiliaus marškiniai", "Džinsiniai marškiniai", "Flaneliniai marškiniai"],
      "Treningo dalys": ["Sportinės kelnės", "Džemperiai be kapišono", "Džemperiai su kapišonu", "Džemperiai su kapišonu ir užtrauktuku", "Džemperiai su užtrauktuku", "Flisiniai džemperiai"],
      "Maudymosi drabužiai": ["Maudymosi šortai", "Glaudės"],
      "Megztiniai": ["Įvairūs megztiniai", "Kardiganai"],
      "Kostiumai ir švarkai": ["Kostiumai", "Švarkai", "Kostiuminės kelnės", "Kostiuminiai švarkai", "Dalykinio stiliaus liemenės"],
      "Paltai": ["Žieminiai paltai", "Demisezoniniai paltai", "Vilnoniai paltai", "Trumpi paltai", "Lietpalčiai"],
      "Proginiai": ["Biuro apranga", "Vestuvės", "Kalėdoms"],
      "Išskirtiniai": ["Marškiniai ir marškinėliai", "Džinsai ir kelnės", "Švarkai ir paltai", "Apatiniai drabužiai ir maudymosi drabužiai", "Megztiniai ir džemperiai"]
    },
    "Batai": {
      "Naujienos": [],
      "Šiuo metu paklausu": [],
      "Sportbačiai": ["Sportbačiai žemu auliuku", "Sportbačiai aukštu auliuku", "Sportbačiai be raištelių", "Medžiaginiai sportbačiai", "Populiariausi sportbačiai"],
      "Atviri batai": ["Basutės", "Įsispiriami bateliai", "Įsispiriamos šlepetės", "Šlepetės", "Žygio basutės"],
      "Bateliai": ["Mokasinai", "Sliperiai", "Klasikiniai batai", "Laisvalaikio batai su raišteliais", "Sportinio stiliaus batai su raišteliais", "Espadrilės"],
      "Sportiniai batai": ["Bėgimo bateliai", "Lauko batai", "Treniruočių bateliai"],
      "Batai ir auliniai batai": ["Auliniai batai", "Auliniai batai su raišteliais", "Batai aukštu aulu"],
      "Išskirtiniai": []
    },
    "Sportas": {
      "Sportiniai drabužiai": [],
      "Sporto šakos": [],
      "Sportiniai batai": [],
      "Sportinės kuprinės ir krepšiai": [],
      "Aksesuarai sportui": []
    },
    "Aksesuarai": {
      "Naujienos": [],
      "Kepurės": [],
      "Krepšiai ir kuprinės": [],
      "Diržai": [],
      "Akiniai nuo saulės": [],
      "Piniginės ir kosmetinės": [],
      "Laikrodžiai": [],
      "Juvelyriniai dirbiniai": [],
      "Kaklaraiščiai ir aksesuarai": [],
      "Šalikai ir šaliai": [],
      "Pirštinės": [],
      "Aksesuarai būstui": [],
      "Išskirtiniai": [],
      "Antrinis panaudojimas": []
    },
    "Streetwear": {
      "Batai": [],
      "Džemperiai": [],
      "Marškinėliai": [],
      "Marškiniai": [],
      "Kelnės ir džinsai": [],
      "Šortai": [],
      "Striukės": [],
      "Megzti drabužiai": [],
      "Treningai": [],
      "Aksesuarai": []
    }
  }
  $taxonomy$::jsonb;
  root_entry record;
  parent_entry record;
  child_name text;
  v_root_id uuid;
  v_parent_id uuid;
  v_child_id uuid;
  root_path text;
  parent_path text;
  child_path text;
  vyrams_id uuid;
begin
  select id into vyrams_id from public.categories where path = 'vyrams';
  if vyrams_id is null then
    raise exception 'Canonical Vyrams category is missing';
  end if;

  for root_entry in select key as name, value as children from jsonb_each(taxonomy)
  loop
    root_path := 'vyrams>' || lower(trim(root_entry.name));
    insert into public.categories(slug, name, parent_id, level, path)
    values ('category-' || md5(root_path), trim(root_entry.name), vyrams_id, 2, root_path)
    on conflict (path) where path is not null do update set
      name = excluded.name, parent_id = excluded.parent_id, level = excluded.level
    returning id into v_root_id;

    for parent_entry in select key as name, value as children from jsonb_each(root_entry.children)
    loop
      parent_path := root_path || '>' || lower(trim(parent_entry.name));
      insert into public.categories(slug, name, parent_id, level, path)
      values ('category-' || md5(parent_path), trim(parent_entry.name), v_root_id, 3, parent_path)
      on conflict (path) where path is not null do update set
        name = excluded.name, parent_id = excluded.parent_id, level = excluded.level
      returning id into v_parent_id;

      -- Reuse legacy flat memberships, scoped by the level-2 root so equal
      -- labels in different menu branches do not get mixed together.
      insert into public.product_categories(product_id, category_id)
      select distinct root_link.product_id, v_parent_id
      from public.product_categories root_link
      join public.product_categories legacy_link on legacy_link.product_id = root_link.product_id
      join public.categories legacy on legacy.id = legacy_link.category_id
      where root_link.category_id = v_root_id
        and legacy.path is null
        and lower(trim(legacy.name)) = lower(trim(parent_entry.name))
      on conflict do nothing;

      for child_name in select jsonb_array_elements_text(parent_entry.children)
      loop
        child_path := parent_path || '>' || lower(trim(child_name));
        insert into public.categories(slug, name, parent_id, level, path)
        values ('category-' || md5(child_path), trim(child_name), v_parent_id, 4, child_path)
        on conflict (path) where path is not null do update set
          name = excluded.name, parent_id = excluded.parent_id, level = excluded.level
        returning id into v_child_id;

        insert into public.product_categories(product_id, category_id)
        select distinct root_link.product_id, node.category_id
        from public.product_categories root_link
        join public.product_categories legacy_link on legacy_link.product_id = root_link.product_id
        join public.categories legacy on legacy.id = legacy_link.category_id
        cross join lateral (values (v_parent_id), (v_child_id)) node(category_id)
        where root_link.category_id = v_root_id
          and legacy.path is null
          and lower(trim(legacy.name)) = lower(trim(child_name))
        on conflict do nothing;
      end loop;
    end loop;
  end loop;
end $$;

-- Some ABOUT YOU breadcrumbs omit the generic "Drabužiai" segment. Those
-- paths were previously accepted as exact and created clothing branches at
-- level 2 (for example Vyrams > Kelnės). Move their product links into the
-- canonical Vyrams > Drabužiai > ... hierarchy and remove the invalid roots.
do $$
declare
  parent_name text;
  bad_root record;
  bad_child record;
  clothes_id uuid;
  canonical_parent_id uuid;
  canonical_child_id uuid;
  canonical_parent_path text;
  canonical_child_path text;
begin
  select id into clothes_id
  from public.categories
  where path = 'vyrams>drabužiai';

  if clothes_id is null then
    raise exception 'Canonical Drabužiai category is missing';
  end if;

  foreach parent_name in array array[
    'Marškinėliai', 'Kelnės', 'Apatiniai', 'Džinsai', 'Striukės',
    'Marškiniai', 'Treningo dalys', 'Maudymosi drabužiai', 'Megztiniai',
    'Kostiumai ir švarkai', 'Paltai', 'Proginiai', 'Išskirtiniai'
  ]
  loop
    canonical_parent_path := 'vyrams>drabužiai>' || lower(parent_name);
    insert into public.categories(slug, name, parent_id, level, path)
    values (
      'category-' || md5(canonical_parent_path), parent_name,
      clothes_id, 3, canonical_parent_path
    )
    on conflict (path) where path is not null do update set
      name = excluded.name, parent_id = excluded.parent_id, level = excluded.level
    returning id into canonical_parent_id;

    for bad_root in
      select id
      from public.categories
      where level = 2
        and lower(name) = lower(parent_name)
        and path is distinct from canonical_parent_path
    loop
      -- Preserve every affected product at both canonical ancestor levels.
      with recursive bad_tree as (
        select id from public.categories where id = bad_root.id
        union all
        select category.id
        from public.categories category
        join bad_tree parent on category.parent_id = parent.id
      ), affected_products as (
        select distinct link.product_id
        from public.product_categories link
        join bad_tree category on category.id = link.category_id
      )
      insert into public.product_categories(product_id, category_id)
      select product_id, category_id
      from affected_products
      cross join lateral (values (clothes_id), (canonical_parent_id)) target(category_id)
      on conflict do nothing;

      -- A child of the malformed level-2 branch belongs at canonical level 4.
      for bad_child in
        select id, name
        from public.categories
        where parent_id = bad_root.id
      loop
        canonical_child_path := canonical_parent_path || '>' || lower(bad_child.name);
        insert into public.categories(slug, name, parent_id, level, path)
        values (
          'category-' || md5(canonical_child_path), bad_child.name,
          canonical_parent_id, 4, canonical_child_path
        )
        on conflict (path) where path is not null do update set
          name = excluded.name, parent_id = excluded.parent_id, level = excluded.level
        returning id into canonical_child_id;

        insert into public.product_categories(product_id, category_id)
        select product_id, canonical_child_id
        from public.product_categories
        where category_id = bad_child.id
        on conflict do nothing;
      end loop;

      delete from public.categories where id = bad_root.id;
    end loop;
  end loop;
end $$;
