create table public.product_raw_sample_members (
  product_id uuid primary key references public.products(id) on delete cascade,
  sample_rank integer not null check (sample_rank > 0),
  selected_at timestamptz not null default now()
);

create table public.product_sync_artifacts (
  id bigint generated always as identity primary key,
  product_id uuid not null references public.products(id) on delete cascade,
  artifact_kind text not null check (artifact_kind in ('success_sample', 'blocked_schema')),
  storage_path text unique,
  payload_hash text check (payload_hash is null or payload_hash ~ '^[0-9a-f]{64}$'),
  content_hash text check (content_hash is null or content_hash ~ '^[0-9a-f]{64}$'),
  parser_version integer not null check (parser_version > 0),
  source_endpoint text,
  error_code text,
  uncompressed_size bigint check (uncompressed_size is null or uncompressed_size >= 0),
  compressed_size bigint check (compressed_size is null or compressed_size >= 0),
  upload_status text not null default 'ready' check (upload_status in ('ready', 'upload_failed')),
  upload_error text,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  check (
    (upload_status = 'ready' and storage_path is not null and content_hash is not null and upload_error is null)
    or (upload_status = 'upload_failed' and storage_path is null and upload_error is not null)
  )
);

create index product_sync_artifacts_product_created_idx
  on public.product_sync_artifacts(product_id, created_at desc);
create index product_sync_artifacts_expiry_idx
  on public.product_sync_artifacts(expires_at)
  where expires_at is not null;

alter table public.product_raw_sample_members enable row level security;
alter table public.product_sync_artifacts enable row level security;
revoke all on table public.product_raw_sample_members from public, anon, authenticated;
revoke all on table public.product_sync_artifacts from public, anon, authenticated;
grant select, insert, update, delete on table public.product_raw_sample_members to service_role;
grant select, insert, update, delete on table public.product_sync_artifacts to service_role;
grant usage, select on sequence public.product_sync_artifacts_id_seq to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sync-raw', 'sync-raw', false, 5242880, array['application/gzip'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.refresh_product_raw_sample_members(p_limit integer default 750)
returns integer language plpgsql security definer set search_path = public as $$
begin
  if p_limit < 1 or p_limit > 1000 then
    raise exception 'Raw sample limit must be between 1 and 1000';
  end if;

  delete from public.product_raw_sample_members member
  where not exists (
    select 1
    from (
      select product.id
      from public.products product
      where product.active
      order by md5(product.id::text), product.id
      limit p_limit
    ) desired
    where desired.id = member.product_id
  );

  insert into public.product_raw_sample_members(product_id, sample_rank, selected_at)
  select desired.id, desired.sample_rank, now()
  from (
    select product.id, row_number() over (order by md5(product.id::text), product.id)::integer as sample_rank
    from public.products product
    where product.active
    order by md5(product.id::text), product.id
    limit p_limit
  ) desired
  on conflict (product_id) do update set sample_rank = excluded.sample_rank;

  return (select count(*)::integer from public.product_raw_sample_members);
end $$;

revoke all on function public.refresh_product_raw_sample_members(integer) from public, anon, authenticated;
grant execute on function public.refresh_product_raw_sample_members(integer) to service_role;

create or replace function public.complete_product_detail(
  p_product_id uuid,
  p_lease_token uuid,
  p_parser_version integer,
  p_payload_hash text,
  p_source_endpoint text,
  p_result jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_section jsonb;
  v_option jsonb;
  v_categories_exact boolean := coalesce((p_result->>'categoriesExact')::boolean, false);
begin
  if not exists (
    select 1 from public.product_detail_sync
    where product_id = p_product_id and status = 'processing'
      and lease_token = p_lease_token and lease_until >= now() and parser_version = p_parser_version
  ) then
    raise exception 'Product detail lease is missing or expired';
  end if;
  if p_payload_hash !~ '^[0-9a-f]{64}$' or trim(p_source_endpoint) = '' then
    raise exception 'Invalid product detail payload metadata';
  end if;
  if jsonb_array_length(coalesce(p_result->'sections', '[]'::jsonb)) <> 4 then
    raise exception 'Every supported product detail section must have a terminal state';
  end if;

  delete from public.product_detail_sections where product_id = p_product_id;
  for v_section in select value from jsonb_array_elements(p_result->'sections') loop
    insert into public.product_detail_sections(
      product_id, section_key, source_label, status, source_type, position, items, parser_version, fetched_at
    ) values (
      p_product_id, v_section->>'key', v_section->>'sourceLabel', v_section->>'status',
      nullif(v_section->>'sourceType', ''), (v_section->>'position')::integer,
      coalesce(v_section->'items', '[]'::jsonb), p_parser_version, now()
    );
  end loop;

  delete from public.product_color_options where product_id = p_product_id;
  for v_option in select value from jsonb_array_elements(coalesce(p_result->'colorOptions', '[]'::jsonb)) loop
    insert into public.product_color_options(product_id, position, external_id, label, url, selected)
    values (
      p_product_id, coalesce((v_option->>'position')::integer, 0), nullif(v_option->>'externalId', ''),
      v_option->>'label', nullif(v_option->>'url', ''), coalesce((v_option->>'selected')::boolean, false)
    );
  end loop;

  delete from public.product_size_options where product_id = p_product_id;
  for v_option in select value from jsonb_array_elements(coalesce(p_result->'sizeOptions', '[]'::jsonb)) loop
    insert into public.product_size_options(
      product_id, external_id, position, label, size_group, selected, selectable, availability
    ) values (
      p_product_id, v_option->>'externalId', (v_option->>'position')::integer, v_option->>'label',
      nullif(v_option->>'group', ''), coalesce((v_option->>'selected')::boolean, false),
      (v_option->>'selectable')::boolean, nullif(v_option->>'availability', '')
    );
  end loop;

  update public.products set
    image_urls = coalesce(p_result->'imageUrls', '[]'::jsonb),
    color_original = nullif(p_result->>'colorOriginal', ''),
    color_family = coalesce(nullif(p_result->>'colorFamily', ''), 'other'),
    color_shade = coalesce(nullif(p_result->>'colorShade', ''), 'other'),
    sizes = array(select jsonb_array_elements_text(coalesce(p_result->'sizes', '[]'::jsonb))),
    other_sizes = array(select jsonb_array_elements_text(coalesce(p_result->'otherSizes', '[]'::jsonb))),
    materials = array(select jsonb_array_elements_text(coalesce(p_result->'materials', '[]'::jsonb))),
    patterns = array(select jsonb_array_elements_text(coalesce(p_result->'patterns', '[]'::jsonb))),
    features = array(select jsonb_array_elements_text(coalesce(p_result->'features', '[]'::jsonb))),
    styles = array(select jsonb_array_elements_text(coalesce(p_result->'styles', '[]'::jsonb))),
    product_types = array(select jsonb_array_elements_text(coalesce(p_result->'productTypes', '[]'::jsonb))),
    is_premium = coalesce((p_result->>'isPremium')::boolean, false),
    detail_checked_at = now(), detail_last_error = null,
    metadata_updated_at = now(), updated_at = now()
  where id = p_product_id and active;
  if not found then raise exception 'Active product not found'; end if;

  if public.record_product_category_path(p_product_id, p_result->'categoryPath', v_categories_exact)
     and v_categories_exact then
    update public.products set category_path_updated_at = now() where id = p_product_id;
  end if;

  update public.product_detail_sync set
    status = 'complete', parser_version = p_parser_version,
    static_synced_at = now(), availability_synced_at = now(), attempt_count = 0,
    next_attempt_at = now() + interval '24 hours', lease_token = null, lease_until = null,
    last_error_code = null, last_http_status = null, updated_at = now()
  where product_id = p_product_id and lease_token = p_lease_token;
end $$;

revoke all on function public.complete_product_detail(uuid, uuid, integer, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.complete_product_detail(uuid, uuid, integer, text, text, jsonb) to service_role;

-- Compatibility wrapper for workers deployed before this migration. It deliberately ignores p_payload.
create or replace function public.complete_product_detail(
  p_product_id uuid,
  p_lease_token uuid,
  p_parser_version integer,
  p_payload jsonb,
  p_payload_hash text,
  p_source_endpoint text,
  p_result jsonb
) returns void language sql security definer set search_path = public as $$
  select public.complete_product_detail(
    p_product_id, p_lease_token, p_parser_version, p_payload_hash, p_source_endpoint, p_result
  );
$$;

revoke all on function public.complete_product_detail(uuid, uuid, integer, jsonb, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.complete_product_detail(uuid, uuid, integer, jsonb, text, text, jsonb) to service_role;
