-- Product-detail metadata is refreshed independently from catalog discovery.
-- Keep detailed values when a catalog tile contains only an empty/null subset.
alter table public.products
  add column if not exists metadata_updated_at timestamptz;

create or replace function public.preserve_product_detail_metadata() returns trigger
language plpgsql set search_path = public as $$
begin
  new.color_original := coalesce(new.color_original, old.color_original);
  if cardinality(new.sizes) = 0 then new.sizes := old.sizes; end if;
  if cardinality(new.other_sizes) = 0 then new.other_sizes := old.other_sizes; end if;
  if cardinality(new.materials) = 0 then new.materials := old.materials; end if;
  if cardinality(new.patterns) = 0 then new.patterns := old.patterns; end if;
  if cardinality(new.features) = 0 then new.features := old.features; end if;
  if cardinality(new.styles) = 0 then new.styles := old.styles; end if;
  if cardinality(new.product_types) = 0 then new.product_types := old.product_types; end if;
  return new;
end $$;

drop trigger if exists a_preserve_product_detail_metadata on public.products;
create trigger a_preserve_product_detail_metadata
before update of color_original, sizes, other_sizes, materials, patterns, features, styles, product_types
on public.products for each row execute function public.preserve_product_detail_metadata();

create or replace function public.record_product_metadata_batch(p_products jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  item jsonb;
  v_product_id uuid;
  v_category text;
  v_category_id uuid;
  v_categories_exact boolean;
  v_count integer := 0;
begin
  for item in select value from jsonb_array_elements(p_products)
  loop
    v_product_id := (item->>'id')::uuid;
    update public.products set
      color_original = coalesce(nullif(item->>'colorOriginal', ''), color_original),
      color_family = case when nullif(item->>'colorOriginal', '') is not null
        then coalesce(nullif(item->>'colorFamily', ''), color_family) else color_family end,
      sizes = case when jsonb_array_length(coalesce(item->'sizes', '[]')) > 0
        then array(select jsonb_array_elements_text(item->'sizes')) else sizes end,
      other_sizes = case when jsonb_array_length(coalesce(item->'otherSizes', '[]')) > 0
        then array(select jsonb_array_elements_text(item->'otherSizes')) else other_sizes end,
      materials = case when jsonb_array_length(coalesce(item->'materials', '[]')) > 0
        then array(select jsonb_array_elements_text(item->'materials')) else materials end,
      patterns = case when jsonb_array_length(coalesce(item->'patterns', '[]')) > 0
        then array(select jsonb_array_elements_text(item->'patterns')) else patterns end,
      features = case when jsonb_array_length(coalesce(item->'features', '[]')) > 0
        then array(select jsonb_array_elements_text(item->'features')) else features end,
      styles = case when jsonb_array_length(coalesce(item->'styles', '[]')) > 0
        then array(select jsonb_array_elements_text(item->'styles')) else styles end,
      product_types = case when jsonb_array_length(coalesce(item->'productTypes', '[]')) > 0
        then array(select jsonb_array_elements_text(item->'productTypes')) else product_types end,
      metadata_updated_at = now(), updated_at = now()
    where id = v_product_id and active;

    if not found then continue; end if;
    v_categories_exact := coalesce((item->>'categoriesExact')::boolean, false);
    if v_categories_exact then
      delete from public.product_categories where product_id = v_product_id;
    end if;

    for v_category in
      select jsonb_array_elements_text(coalesce(item->'categories', '[]'))
      union
      select t.label from public.sync_target_products stp
      join public.sync_targets t on t.id = stp.target_id
      where stp.product_id = v_product_id and stp.active and t.kind = 'category'
    loop
      v_category_id := null;
      select id into v_category_id from public.categories where lower(name) = lower(v_category) limit 1;
      if v_category_id is null then
        insert into public.categories(slug, name)
        values ('category-' || md5(lower(v_category)), v_category)
        on conflict (slug) do update set name = excluded.name returning id into v_category_id;
      end if;
      insert into public.product_categories(product_id, category_id)
      values (v_product_id, v_category_id) on conflict do nothing;
    end loop;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

revoke all on function public.preserve_product_detail_metadata() from public, anon, authenticated;
revoke all on function public.record_product_metadata_batch(jsonb) from public, anon, authenticated;
grant execute on function public.record_product_metadata_batch(jsonb) to service_role;
