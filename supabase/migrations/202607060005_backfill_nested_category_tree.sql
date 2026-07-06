-- Make the existing flat catalog immediately expandable while exact product
-- breadcrumbs are progressively refreshed. These mappings are only a backfill:
-- a later exact breadcrumb replaces every provisional product association.
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
begin
  for root_entry in select key as name, value as children from jsonb_each(taxonomy)
  loop
    root_path := 'vyrams>' || lower(root_entry.name);
    select category.id into v_root_id from public.categories category where category.path = root_path;
    if v_root_id is null then continue; end if;

    for parent_entry in select key as name, value as children from jsonb_each(root_entry.children)
    loop
      parent_path := root_path || '>' || lower(parent_entry.name);
      select category.id into v_parent_id from public.categories category where category.path = parent_path;
      if v_parent_id is null then
        insert into public.categories(slug, name, parent_id, level, path)
        values ('category-' || md5(parent_path), parent_entry.name, v_root_id, 3, parent_path)
        on conflict (path) where path is not null do update set name = excluded.name
        returning id into v_parent_id;
      end if;

      -- A product must belong to the matching level-2 root as well as the old
      -- flat category, which disambiguates repeated labels across branches.
      insert into public.product_categories(product_id, category_id)
      select distinct root_link.product_id, v_parent_id
      from public.product_categories root_link
      join public.product_categories legacy_link on legacy_link.product_id = root_link.product_id
      join public.categories legacy on legacy.id = legacy_link.category_id
      where root_link.category_id = v_root_id
        and legacy.path is null
        and lower(legacy.name) = lower(parent_entry.name)
      on conflict do nothing;

      for child_name in select jsonb_array_elements_text(parent_entry.children)
      loop
        child_path := parent_path || '>' || lower(child_name);
        select category.id into v_child_id from public.categories category where category.path = child_path;
        if v_child_id is null then
          insert into public.categories(slug, name, parent_id, level, path)
          values ('category-' || md5(child_path), child_name, v_parent_id, 4, child_path)
          on conflict (path) where path is not null do update set name = excluded.name
          returning id into v_child_id;
        end if;

        insert into public.product_categories(product_id, category_id)
        select distinct root_link.product_id, node.category_id
        from public.product_categories root_link
        join public.product_categories legacy_link on legacy_link.product_id = root_link.product_id
        join public.categories legacy on legacy.id = legacy_link.category_id
        cross join lateral (values (v_parent_id), (v_child_id)) node(category_id)
        where root_link.category_id = v_root_id
          and legacy.path is null
          and lower(legacy.name) = lower(child_name)
        on conflict do nothing;
      end loop;
    end loop;
  end loop;
end $$;
