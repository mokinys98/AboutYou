-- Reliable, versioned product-detail ingestion with atomic claims and writes.
create table public.product_detail_sync (
  product_id uuid primary key references public.products(id) on delete cascade,
  status text not null default 'pending' check (status in (
    'pending', 'processing', 'complete', 'retryable_error', 'blocked_schema', 'source_unavailable'
  )),
  parser_version integer not null default 0 check (parser_version >= 0),
  static_synced_at timestamptz,
  availability_synced_at timestamptz,
  attempt_count integer not null default 0 check (attempt_count >= 0),
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  last_error_code text,
  last_http_status integer,
  source_url text,
  updated_at timestamptz not null default now(),
  check ((status = 'processing') = (lease_token is not null and lease_until is not null))
);

create table public.product_detail_sections (
  product_id uuid not null references public.products(id) on delete cascade,
  section_key text not null check (section_key in (
    'size_and_fit', 'measurements', 'material_composition', 'design_and_extras'
  )),
  source_label text not null,
  status text not null check (status in ('present', 'source_absent')),
  source_type text,
  position integer not null check (position >= 0),
  items jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array'),
  parser_version integer not null check (parser_version > 0),
  fetched_at timestamptz not null default now(),
  primary key (product_id, section_key),
  check ((status = 'present' and jsonb_array_length(items) > 0) or (status = 'source_absent' and jsonb_array_length(items) = 0))
);

create table public.product_color_options (
  product_id uuid not null references public.products(id) on delete cascade,
  position integer not null check (position >= 0),
  external_id text,
  label text not null check (trim(label) <> ''),
  url text,
  selected boolean not null default false,
  fetched_at timestamptz not null default now(),
  primary key (product_id, position)
);

create table public.product_size_options (
  product_id uuid not null references public.products(id) on delete cascade,
  external_id text not null check (trim(external_id) <> ''),
  position integer not null check (position >= 0),
  label text not null check (trim(label) <> ''),
  size_group text,
  selected boolean not null default false,
  selectable boolean not null,
  availability text,
  fetched_at timestamptz not null default now(),
  primary key (product_id, external_id),
  unique (product_id, position)
);

create index product_detail_sync_pending_idx
  on public.product_detail_sync(parser_version, next_attempt_at, lease_until, product_id)
  where status in ('pending', 'retryable_error', 'processing', 'complete');

alter table public.product_detail_sync enable row level security;
alter table public.product_detail_sections enable row level security;
alter table public.product_color_options enable row level security;
alter table public.product_size_options enable row level security;

revoke all on table public.product_detail_sync, public.product_detail_sections,
  public.product_color_options, public.product_size_options from public, anon, authenticated;
grant all on table public.product_detail_sync, public.product_detail_sections,
  public.product_color_options, public.product_size_options to service_role;

insert into public.product_detail_sync(product_id)
select id from public.products
on conflict (product_id) do nothing;

-- Catalog discovery may seed attributes only until authoritative detail metadata exists.
create or replace function public.preserve_product_detail_metadata() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.metadata_updated_at is not null
     and new.metadata_updated_at is not distinct from old.metadata_updated_at then
    new.color_original := old.color_original;
    new.color_family := old.color_family;
    new.color_shade := old.color_shade;
    new.sizes := old.sizes;
    new.other_sizes := old.other_sizes;
    new.materials := old.materials;
    new.patterns := old.patterns;
    new.features := old.features;
    new.styles := old.styles;
    new.product_types := old.product_types;
  end if;
  return new;
end $$;

create or replace function public.claim_product_detail_batch(
  p_parser_version integer,
  p_limit integer default 25,
  p_lease_minutes integer default 20
) returns table (
  id uuid,
  source_id uuid,
  external_id text,
  name text,
  brand text,
  product_url text,
  lease_token uuid
) language plpgsql security definer set search_path = public as $$
declare
  v_lease_token uuid := gen_random_uuid();
begin
  if p_parser_version <= 0 or p_limit < 1 or p_limit > 500 or p_lease_minutes < 1 or p_lease_minutes > 60 then
    raise exception 'Invalid product detail claim parameters';
  end if;

  insert into public.product_detail_sync(product_id)
  select product.id from public.products product where product.active
  on conflict (product_id) do nothing;

  return query
  with candidates as (
    select sync.product_id, product.product_url
    from public.product_detail_sync sync
    join public.products product on product.id = sync.product_id and product.active
    where
      sync.parser_version < p_parser_version
      or (sync.status in ('pending', 'retryable_error', 'complete') and sync.next_attempt_at <= now())
      or (sync.status = 'processing' and sync.lease_until < now())
      or (sync.status = 'source_unavailable' and sync.source_url is distinct from product.product_url)
    order by
      case when sync.parser_version < p_parser_version then 0
           when sync.status in ('pending', 'retryable_error') then 1
           when sync.status = 'processing' then 2 else 3 end,
      sync.next_attempt_at,
      sync.availability_synced_at nulls first,
      sync.product_id
    limit p_limit
    for update of sync skip locked
  ), claimed as (
    update public.product_detail_sync sync set
      status = 'processing',
      parser_version = p_parser_version,
      attempt_count = case when sync.parser_version <> p_parser_version then 0 else sync.attempt_count end,
      lease_token = v_lease_token,
      lease_until = now() + make_interval(mins => p_lease_minutes),
      last_error_code = null,
      last_http_status = null,
      source_url = candidates.product_url,
      updated_at = now()
    from candidates
    where sync.product_id = candidates.product_id
    returning sync.product_id
  )
  select product.id, product.source_id, product.external_id, product.name, product.brand,
    product.product_url, v_lease_token
  from claimed
  join public.products product on product.id = claimed.product_id
  order by product.id;
end $$;

create or replace function public.complete_product_detail(
  p_product_id uuid,
  p_lease_token uuid,
  p_parser_version integer,
  p_payload jsonb,
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
  if jsonb_typeof(p_payload) <> 'object' or p_payload_hash !~ '^[0-9a-f]{64}$'
     or trim(p_source_endpoint) = '' then
    raise exception 'Invalid product detail payload';
  end if;
  if jsonb_array_length(coalesce(p_result->'sections', '[]'::jsonb)) <> 4 then
    raise exception 'Every supported product detail section must have a terminal state';
  end if;

  insert into public.product_detail_raw(product_id, payload, payload_hash, fetched_at, source_endpoint, parser_version)
  values (p_product_id, p_payload, p_payload_hash, now(), p_source_endpoint, p_parser_version)
  on conflict (product_id) do update set
    payload = case when product_detail_raw.payload_hash is distinct from excluded.payload_hash then excluded.payload else product_detail_raw.payload end,
    payload_hash = excluded.payload_hash,
    fetched_at = excluded.fetched_at,
    source_endpoint = excluded.source_endpoint,
    parser_version = excluded.parser_version;

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
  for v_option in select value from jsonb_array_elements(coalesce(p_result->'colorOptions', '[]'::jsonb)) with ordinality loop
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

create or replace function public.fail_product_detail(
  p_product_id uuid,
  p_lease_token uuid,
  p_error_kind text,
  p_error_code text,
  p_http_status integer default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_attempt integer;
begin
  select attempt_count into v_attempt
  from public.product_detail_sync
  where product_id = p_product_id and status = 'processing' and lease_token = p_lease_token
  for update;
  if not found then raise exception 'Product detail lease is missing'; end if;

  if p_error_kind = 'rate_limited' then
    update public.product_detail_sync set status = 'pending', next_attempt_at = now(),
      lease_token = null, lease_until = null, last_error_code = p_error_code,
      last_http_status = p_http_status, updated_at = now()
    where product_id = p_product_id;
  elsif p_error_kind = 'blocked_schema' then
    update public.product_detail_sync set status = 'blocked_schema', next_attempt_at = 'infinity',
      lease_token = null, lease_until = null, last_error_code = p_error_code,
      last_http_status = p_http_status, updated_at = now()
    where product_id = p_product_id;
  elsif p_error_kind = 'source_unavailable' then
    update public.product_detail_sync set status = 'source_unavailable', next_attempt_at = 'infinity',
      lease_token = null, lease_until = null, last_error_code = p_error_code,
      last_http_status = p_http_status, updated_at = now()
    where product_id = p_product_id;
  elsif p_error_kind = 'retryable' then
    v_attempt := v_attempt + 1;
    update public.product_detail_sync set status = 'retryable_error', attempt_count = v_attempt,
      next_attempt_at = case v_attempt when 1 then now() + interval '15 minutes'
        when 2 then now() + interval '2 hours' else 'infinity'::timestamptz end,
      lease_token = null, lease_until = null, last_error_code = p_error_code,
      last_http_status = p_http_status, updated_at = now()
    where product_id = p_product_id;
  else
    raise exception 'Unknown product detail error kind';
  end if;

  update public.products set detail_checked_at = now(), detail_last_error = p_error_code
  where id = p_product_id;
end $$;

create or replace function public.release_product_detail_claim(p_lease_token uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  update public.product_detail_sync set status = 'pending', next_attempt_at = now(),
    lease_token = null, lease_until = null, updated_at = now()
  where status = 'processing' and lease_token = p_lease_token;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

create or replace function public.product_detail_sync_summary(p_parser_version integer)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'parserVersion', p_parser_version,
    'active', count(*),
    'complete', count(*) filter (where sync.status = 'complete' and sync.parser_version = p_parser_version),
    'pending', count(*) filter (where sync.parser_version < p_parser_version or sync.status in ('pending', 'processing')),
    'retryable', count(*) filter (where sync.status = 'retryable_error'),
    'blockedSchema', count(*) filter (where sync.status = 'blocked_schema' and sync.parser_version = p_parser_version),
    'sourceUnavailable', count(*) filter (where sync.status = 'source_unavailable' and sync.parser_version = p_parser_version)
  )
  from public.products product
  join public.product_detail_sync sync on sync.product_id = product.id
  where product.active;
$$;

revoke all on function public.claim_product_detail_batch(integer, integer, integer) from public, anon, authenticated;
revoke all on function public.complete_product_detail(uuid, uuid, integer, jsonb, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.fail_product_detail(uuid, uuid, text, text, integer) from public, anon, authenticated;
revoke all on function public.release_product_detail_claim(uuid) from public, anon, authenticated;
revoke all on function public.product_detail_sync_summary(integer) from public, anon, authenticated;
grant execute on function public.claim_product_detail_batch(integer, integer, integer) to service_role;
grant execute on function public.complete_product_detail(uuid, uuid, integer, jsonb, text, text, jsonb) to service_role;
grant execute on function public.fail_product_detail(uuid, uuid, text, text, integer) to service_role;
grant execute on function public.release_product_detail_claim(uuid) to service_role;
grant execute on function public.product_detail_sync_summary(integer) to service_role;

-- Disable the legacy partial writer; all authoritative detail writes must use the leased transaction above.
revoke execute on function public.record_product_metadata_batch(jsonb) from service_role;
