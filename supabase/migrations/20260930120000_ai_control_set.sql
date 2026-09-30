-- AI control set. Run this entire file in the VPS Supabase SQL Editor.
-- No API call is made by this migration.
begin;

create table public.ai_control_sets (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  catalog_url text not null,
  filters jsonb not null default '{}'::jsonb check (jsonb_typeof(filters) = 'object'),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.ai_control_items (
  set_id uuid not null references public.ai_control_sets(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  added_at timestamptz not null default now(),
  human_color_family text,
  human_color_shade text,
  human_temperature text check (human_temperature in ('warm','cool','neutral','unknown')),
  human_lightness text check (human_lightness in ('light','medium','dark','unknown')),
  human_saturation text check (human_saturation in ('muted','medium','vivid','unknown')),
  human_contrast text check (human_contrast in ('low','medium','high','unknown')),
  human_visual_pattern text check (human_visual_pattern in ('solid','striped','checked','floral','graphic','other','unknown')),
  review_note text check (length(review_note) <= 500),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  primary key (set_id, product_id)
);
create index ai_control_items_product_idx on public.ai_control_items (product_id);

create table public.product_ai_attributes (
  product_id uuid primary key references public.products(id) on delete cascade,
  dominant_color_family text not null,
  dominant_color_shade text not null,
  secondary_color_families text[] not null default '{}' check (cardinality(secondary_color_families) <= 2),
  temperature text not null check (temperature in ('warm','cool','neutral','unknown')),
  lightness text not null check (lightness in ('light','medium','dark','unknown')),
  saturation text not null check (saturation in ('muted','medium','vivid','unknown')),
  contrast text not null check (contrast in ('low','medium','high','unknown')),
  visual_pattern text not null check (visual_pattern in ('solid','striped','checked','floral','graphic','other','unknown')),
  confidence numeric(3,2) not null check (confidence between 0 and 1),
  needs_review boolean not null,
  source_image_url text not null,
  source_image_fingerprint text not null,
  metadata_fingerprint text not null,
  schema_version integer not null check (schema_version > 0),
  prompt_version integer not null check (prompt_version > 0),
  model text not null,
  analyzed_at timestamptz not null default now()
);
create table public.ai_daily_usage (
  usage_day date primary key,
  reserved_total integer not null default 0 check (reserved_total >= 0),
  actual_total integer not null default 0 check (actual_total >= 0),
  updated_at timestamptz not null default now()
);

create table public.ai_control_requests (
  id uuid primary key default gen_random_uuid(),
  set_id uuid not null,
  product_id uuid not null,
  usage_day date not null references public.ai_daily_usage(usage_day),
  image_url text not null,
  reserved_tokens integer not null check (reserved_tokens between 1 and 20000),
  actual_tokens integer check (actual_tokens >= 0),
  status text not null check (status in ('reserved','completed','uncertain','reconciled')),
  error_code text check (length(error_code) <= 80),
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
-- A lost response blocks further requests until an operator reconciles it.
create unique index ai_control_one_in_flight_idx on public.ai_control_requests ((true))
  where status in ('reserved','uncertain');
create index ai_control_requests_item_idx on public.ai_control_requests (set_id, product_id, created_at desc);

create view public.ai_control_pending with (security_invoker = true) as
select i.set_id, i.product_id, i.added_at
from public.ai_control_items i
join public.products p on p.id = i.product_id and p.active
left join public.product_ai_attributes a on a.product_id = i.product_id
where p.image_urls->>0 is not null
  and (a.product_id is null or a.source_image_url is distinct from p.image_urls->>0
    or a.schema_version <> 1 or a.prompt_version <> 1);

alter table public.ai_control_sets enable row level security;
alter table public.ai_control_items enable row level security;
alter table public.product_ai_attributes enable row level security;
alter table public.ai_daily_usage enable row level security;
alter table public.ai_control_requests enable row level security;
revoke all on public.ai_control_sets, public.ai_control_items, public.product_ai_attributes,
  public.ai_daily_usage, public.ai_control_requests from public, anon, authenticated;
revoke all on public.ai_control_pending from public, anon, authenticated;
grant select, insert, update, delete on public.ai_control_sets, public.ai_control_items,
  public.product_ai_attributes, public.ai_control_requests to service_role;
grant select, insert, update on public.ai_daily_usage to service_role;
grant select on public.ai_control_pending to service_role;

create function public.reserve_ai_control_request(
  p_set_id uuid, p_product_id uuid, p_image_url text, p_cap integer, p_reserve integer
) returns uuid language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  v_day date := (now() at time zone 'UTC')::date;
  v_total integer;
  v_id uuid;
begin
  if p_cap is null or p_reserve is null or p_cap not between 1 and 200000
     or p_reserve not between 1 and 20000 or p_image_url is null then
    raise exception 'Invalid AI budget or image';
  end if;
  if not exists (
    select 1 from public.ai_control_items i
    join public.products p on p.id = i.product_id
    where i.set_id = p_set_id and i.product_id = p_product_id and p.active
      and p.image_urls->>0 = p_image_url
  ) then
    raise exception 'Control item or current image not found';
  end if;
  insert into public.ai_daily_usage(usage_day) values (v_day) on conflict do nothing;
  select reserved_total into v_total from public.ai_daily_usage where usage_day = v_day for update;
  if exists (select 1 from public.ai_control_requests where status in ('reserved','uncertain')) then
    raise exception 'Another AI request is unresolved';
  end if;
  if v_total + p_reserve > p_cap then
    raise exception 'AI daily token budget exhausted';
  end if;
  insert into public.ai_control_requests(set_id, product_id, usage_day, image_url, reserved_tokens, status)
  values (p_set_id, p_product_id, v_day, p_image_url, p_reserve, 'reserved') returning id into v_id;
  update public.ai_daily_usage set reserved_total = reserved_total + p_reserve, updated_at = now()
  where usage_day = v_day;
  return v_id;
end $$;

create function public.finish_ai_control_request(
  p_request_id uuid, p_attributes jsonb, p_input_tokens integer, p_output_tokens integer,
  p_image_fingerprint text, p_metadata_fingerprint text, p_model text
) returns boolean language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  v_request public.ai_control_requests%rowtype;
  v_current_image text;
  v_total integer;
begin
  select * into v_request from public.ai_control_requests where id = p_request_id for update;
  if not found or v_request.status <> 'reserved' then raise exception 'AI request is not reserved'; end if;
  if p_input_tokens < 0 or p_output_tokens < 0 or p_input_tokens is null or p_output_tokens is null then
    raise exception 'Missing token usage';
  end if;
  v_total := p_input_tokens + p_output_tokens;
  select image_urls->>0 into v_current_image from public.products where id = v_request.product_id;
  if v_current_image = v_request.image_url then
    insert into public.product_ai_attributes (
      product_id, dominant_color_family, dominant_color_shade, secondary_color_families,
      temperature, lightness, saturation, contrast, visual_pattern, confidence, needs_review,
      source_image_url, source_image_fingerprint, metadata_fingerprint, schema_version,
      prompt_version, model, analyzed_at
    ) values (
      v_request.product_id, p_attributes->>'dominantColorFamily', p_attributes->>'dominantColorShade',
      array(select jsonb_array_elements_text(p_attributes->'secondaryColorFamilies')),
      p_attributes->>'temperature', p_attributes->>'lightness', p_attributes->>'saturation',
      p_attributes->>'contrast', p_attributes->>'visualPattern', (p_attributes->>'confidence')::numeric,
      (p_attributes->>'needsReview')::boolean, v_request.image_url, p_image_fingerprint,
      p_metadata_fingerprint, 1, 1, p_model, now()
    ) on conflict (product_id) do update set
      dominant_color_family = excluded.dominant_color_family,
      dominant_color_shade = excluded.dominant_color_shade,
      secondary_color_families = excluded.secondary_color_families,
      temperature = excluded.temperature, lightness = excluded.lightness,
      saturation = excluded.saturation, contrast = excluded.contrast,
      visual_pattern = excluded.visual_pattern, confidence = excluded.confidence,
      needs_review = excluded.needs_review, source_image_url = excluded.source_image_url,
      source_image_fingerprint = excluded.source_image_fingerprint,
      metadata_fingerprint = excluded.metadata_fingerprint, schema_version = excluded.schema_version,
      prompt_version = excluded.prompt_version, model = excluded.model, analyzed_at = now();
  end if;
  update public.ai_daily_usage set
    reserved_total = reserved_total - v_request.reserved_tokens + v_total,
    actual_total = actual_total + v_total, updated_at = now()
  where usage_day = v_request.usage_day;
  update public.ai_control_requests set status = 'completed', actual_tokens = v_total, finished_at = now()
  where id = p_request_id;
  return v_current_image = v_request.image_url;
end $$;

-- Reconcile only from the server after checking OpenAI Usage for this request.
create function public.reconcile_ai_control_request(p_request_id uuid, p_actual_tokens integer)
returns void language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_request public.ai_control_requests%rowtype;
begin
  select * into v_request from public.ai_control_requests where id = p_request_id for update;
  if not found or v_request.status not in ('reserved','uncertain')
     or (v_request.status = 'reserved' and v_request.created_at > now() - interval '2 minutes')
     or p_actual_tokens is null or p_actual_tokens < 0 then
    raise exception 'Invalid reconciliation';
  end if;
  update public.ai_daily_usage set
    reserved_total = reserved_total - v_request.reserved_tokens + p_actual_tokens,
    actual_total = actual_total + p_actual_tokens, updated_at = now()
  where usage_day = v_request.usage_day;
  update public.ai_control_requests set status = 'reconciled', actual_tokens = p_actual_tokens, finished_at = now()
  where id = p_request_id;
end $$;

revoke all on function public.reserve_ai_control_request(uuid,uuid,text,integer,integer),
  public.finish_ai_control_request(uuid,jsonb,integer,integer,text,text,text),
  public.reconcile_ai_control_request(uuid,integer) from public, anon, authenticated;
grant execute on function public.reserve_ai_control_request(uuid,uuid,text,integer,integer),
  public.finish_ai_control_request(uuid,jsonb,integer,integer,text,text,text),
  public.reconcile_ai_control_request(uuid,integer) to service_role;

commit;
notify pgrst, 'reload schema';
