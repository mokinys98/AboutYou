-- Catalog cards do not always expose an image. An empty catalog result is not
-- authoritative and must not erase images collected by the product detail sync.
create or replace function public.record_catalog_batch(
  p_source_id uuid,
  p_target_id uuid,
  p_run_id uuid,
  p_products jsonb
) returns integer language plpgsql security definer set search_path = public as $$
declare
  item jsonb;
  v_product_id uuid;
  v_count integer := 0;
  v_categories_exact boolean;
  v_category_path_updated_at timestamptz;
begin
  for item in select value from jsonb_array_elements(p_products)
  loop
    insert into public.products as existing (
      source_id, external_id, name, brand, product_url, image_urls,
      color_original, color_family, color_shade, sizes, other_sizes, materials, patterns,
      features, styles, product_types, active, last_seen_at, updated_at
    ) values (
      p_source_id, item->>'externalId', item->>'name', coalesce(item->>'brand', ''),
      item->>'productUrl', coalesce(item->'imageUrls', '[]'::jsonb), item->>'colorOriginal',
      coalesce(item->>'colorFamily', 'other'), coalesce(item->>'colorShade', 'other'),
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
      image_urls = case
        when jsonb_array_length(excluded.image_urls) > 0 then excluded.image_urls
        else existing.image_urls
      end,
      color_original = excluded.color_original,
      color_family = excluded.color_family, color_shade = excluded.color_shade,
      sizes = excluded.sizes, other_sizes = excluded.other_sizes, materials = excluded.materials,
      patterns = excluded.patterns, features = excluded.features, styles = excluded.styles,
      product_types = excluded.product_types, active = true, last_seen_at = now(), updated_at = now()
    returning id, category_path_updated_at into v_product_id, v_category_path_updated_at;

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
    if v_categories_exact or v_category_path_updated_at is null then
      if public.record_product_category_path(v_product_id, item->'categoryPath', v_categories_exact) and v_categories_exact then
        update public.products set category_path_updated_at = now() where id = v_product_id;
      end if;
    end if;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

revoke all on function public.record_catalog_batch(uuid, uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.record_catalog_batch(uuid, uuid, uuid, jsonb) to service_role;

-- Repair every product affected by the same race, including the six reported
-- products. Preserve source ordering while removing duplicate image URLs.
with raw_images as (
  select
    raw.product_id,
    trim(source_image.value->'image'->>'src') as image_url,
    source_image.ordinality as position
  from public.product_detail_raw raw
  cross join lateral jsonb_array_elements(
    case
      when jsonb_typeof(raw.payload->'imagesSection'->'images') = 'array'
        then raw.payload->'imagesSection'->'images'
      else '[]'::jsonb
    end
  ) with ordinality as source_image(value, ordinality)
  where nullif(trim(source_image.value->'image'->>'src'), '') is not null
    and trim(source_image.value->'image'->>'src') ~ '^https?://'
), unique_images as (
  select product_id, image_url, min(position) as position
  from raw_images
  group by product_id, image_url
), extracted as (
  select product_id, jsonb_agg(image_url order by position) as image_urls
  from unique_images
  group by product_id
)
update public.products product
set image_urls = extracted.image_urls
from extracted
where product.id = extracted.product_id
  and jsonb_array_length(coalesce(product.image_urls, '[]'::jsonb)) = 0
  and jsonb_array_length(extracted.image_urls) > 0;
