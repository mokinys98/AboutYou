-- Source-backed categories (ABOUT YOU tile or product JSON-LD breadcrumb) are
-- authoritative. Replace stale category memberships when such data is present;
-- keep additive behavior only for heuristic fallback categories.
create or replace function public.record_catalog_batch(
  p_source_id uuid,
  p_target_id uuid,
  p_run_id uuid,
  p_products jsonb
) returns integer language plpgsql security definer set search_path = public as $$
declare
  item jsonb;
  v_product_id uuid;
  v_category text;
  v_category_id uuid;
  v_count integer := 0;
  v_categories_exact boolean;
begin
  for item in select value from jsonb_array_elements(p_products)
  loop
    insert into public.products (
      source_id, external_id, name, brand, product_url, image_urls,
      color_original, color_family, sizes, other_sizes, materials, patterns,
      features, styles, product_types, active, last_seen_at, updated_at
    ) values (
      p_source_id, item->>'externalId', item->>'name', coalesce(item->>'brand', ''),
      item->>'productUrl', coalesce(item->'imageUrls', '[]'::jsonb), item->>'colorOriginal',
      coalesce(item->>'colorFamily', 'other'),
      array(select jsonb_array_elements_text(coalesce(item->'sizes', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'otherSizes', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'materials', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'patterns', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'features', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'styles', '[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(item->'productTypes', '[]'::jsonb))),
      true, now(), now()
    )
    on conflict (source_id, external_id) do update set
      name = excluded.name, brand = excluded.brand, product_url = excluded.product_url,
      image_urls = excluded.image_urls, color_original = excluded.color_original,
      color_family = excluded.color_family, sizes = excluded.sizes, other_sizes = excluded.other_sizes,
      materials = excluded.materials, patterns = excluded.patterns, features = excluded.features,
      styles = excluded.styles, product_types = excluded.product_types,
      active = true, last_seen_at = now(), updated_at = now()
    returning id into v_product_id;

    perform public.record_price_observation(
      v_product_id, (item->>'currentPrice')::integer,
      nullif(item->>'originalPrice', '')::integer, nullif(item->>'sourceLpl30', '')::integer,
      coalesce(item->>'currency', 'EUR')::char(3)
    );

    insert into public.sync_target_products(target_id, product_id, last_seen_run_id, missing_successful_runs, active)
    values (p_target_id, v_product_id, p_run_id, 0, true)
    on conflict (target_id, product_id) do update set
      last_seen_run_id = excluded.last_seen_run_id, missing_successful_runs = 0, active = true;

    v_categories_exact := coalesce((item->>'categoriesExact')::boolean, false);
    if v_categories_exact then
      delete from public.product_categories where product_id = v_product_id;
    end if;

    for v_category in select jsonb_array_elements_text(coalesce(item->'categories', '[]'::jsonb))
    loop
      v_category_id := null;
      select id into v_category_id from public.categories where lower(name) = lower(v_category) limit 1;
      if v_category_id is null then
        insert into public.categories(slug, name) values ('category-' || md5(lower(v_category)), v_category)
        on conflict (slug) do update set name = excluded.name returning id into v_category_id;
      end if;
      insert into public.product_categories(product_id, category_id)
      values (v_product_id, v_category_id) on conflict do nothing;
    end loop;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

grant execute on function public.record_catalog_batch(uuid, uuid, uuid, jsonb) to service_role;
