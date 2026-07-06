-- Keep one current, sanitized product-detail API payload per product.
alter table public.products
  add column if not exists detail_checked_at timestamptz,
  add column if not exists detail_last_error text;

create index if not exists products_detail_refresh_idx
  on public.products(detail_checked_at asc nulls first, source_id, id)
  where active;

create table public.product_detail_raw (
  product_id uuid primary key references public.products(id) on delete cascade,
  payload jsonb not null,
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  fetched_at timestamptz not null default now(),
  source_endpoint text not null check (trim(source_endpoint) <> ''),
  parser_version integer not null check (parser_version > 0)
);

alter table public.product_detail_raw enable row level security;
revoke all on table public.product_detail_raw from public, anon, authenticated;
grant all on table public.product_detail_raw to service_role;

create or replace function public.record_product_metadata_batch(p_products jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  item jsonb;
  v_product_id uuid;
  v_categories_exact boolean;
  v_metadata_found boolean;
  v_count integer := 0;
begin
  for item in select value from jsonb_array_elements(p_products)
  loop
    v_product_id := (item->>'id')::uuid;
    v_metadata_found := coalesce((item->>'metadataFound')::boolean, false);

    update public.products set
      detail_checked_at = now(),
      detail_last_error = nullif(item->>'detailError', '')
    where id = v_product_id and active;
    if not found then continue; end if;

    if item->'rawPayload' is not null
       and item->'rawPayload' <> 'null'::jsonb
       and nullif(item->>'payloadHash', '') is not null
       and nullif(item->>'sourceEndpoint', '') is not null
       and coalesce((item->>'parserVersion')::integer, 0) > 0 then
      insert into public.product_detail_raw(
        product_id, payload, payload_hash, fetched_at, source_endpoint, parser_version
      ) values (
        v_product_id,
        item->'rawPayload',
        item->>'payloadHash',
        now(),
        item->>'sourceEndpoint',
        (item->>'parserVersion')::integer
      )
      on conflict (product_id) do update set
        payload = case
          when product_detail_raw.payload_hash is distinct from excluded.payload_hash then excluded.payload
          else product_detail_raw.payload
        end,
        payload_hash = excluded.payload_hash,
        fetched_at = excluded.fetched_at,
        source_endpoint = excluded.source_endpoint,
        parser_version = excluded.parser_version;
    end if;

    if v_metadata_found then
      update public.products set
        image_urls = case when jsonb_array_length(coalesce(item->'imageUrls', '[]')) > 0 then item->'imageUrls' else image_urls end,
        color_original = coalesce(nullif(item->>'colorOriginal', ''), color_original),
        color_family = case when nullif(item->>'colorOriginal', '') is not null then coalesce(nullif(item->>'colorFamily', ''), color_family) else color_family end,
        color_shade = case when nullif(item->>'colorOriginal', '') is not null then coalesce(nullif(item->>'colorShade', ''), color_shade) else color_shade end,
        sizes = case when jsonb_array_length(coalesce(item->'sizes', '[]')) > 0 then array(select jsonb_array_elements_text(item->'sizes')) else sizes end,
        other_sizes = case when jsonb_array_length(coalesce(item->'otherSizes', '[]')) > 0 then array(select jsonb_array_elements_text(item->'otherSizes')) else other_sizes end,
        materials = case when jsonb_array_length(coalesce(item->'materials', '[]')) > 0 then array(select jsonb_array_elements_text(item->'materials')) else materials end,
        patterns = case when jsonb_array_length(coalesce(item->'patterns', '[]')) > 0 then array(select jsonb_array_elements_text(item->'patterns')) else patterns end,
        features = case when jsonb_array_length(coalesce(item->'features', '[]')) > 0 then array(select jsonb_array_elements_text(item->'features')) else features end,
        styles = case when jsonb_array_length(coalesce(item->'styles', '[]')) > 0 then array(select jsonb_array_elements_text(item->'styles')) else styles end,
        product_types = case when jsonb_array_length(coalesce(item->'productTypes', '[]')) > 0 then array(select jsonb_array_elements_text(item->'productTypes')) else product_types end,
        metadata_updated_at = now(),
        updated_at = now()
      where id = v_product_id and active;

      v_categories_exact := coalesce((item->>'categoriesExact')::boolean, false);
      if public.record_product_category_path(v_product_id, item->'categoryPath', v_categories_exact) and v_categories_exact then
        update public.products set category_path_updated_at = now() where id = v_product_id;
      end if;
    end if;

    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

revoke all on function public.record_product_metadata_batch(jsonb) from public, anon, authenticated;
grant execute on function public.record_product_metadata_batch(jsonb) to service_role;
