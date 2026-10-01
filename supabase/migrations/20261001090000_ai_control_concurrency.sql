-- Run this entire file in the VPS Supabase SQL Editor before publishing the concurrent admin UI.
-- Apply only when no AI control request is reserved or uncertain.
begin;

lock table public.ai_control_requests in access exclusive mode;

do $$
begin
  if exists (
    select 1 from public.ai_control_requests where status in ('reserved', 'uncertain')
  ) then
    raise exception 'Reconcile or finish all AI requests before enabling concurrency';
  end if;
end $$;

drop index if exists public.ai_control_one_in_flight_idx;
create unique index ai_control_product_in_flight_idx
  on public.ai_control_requests (product_id)
  where status in ('reserved', 'uncertain');
create index ai_control_unresolved_status_idx
  on public.ai_control_requests (status)
  where status in ('reserved', 'uncertain');

create or replace function public.reserve_ai_control_request(
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

  -- Serialize reservations globally, including requests crossing a UTC day boundary.
  -- This lock is released when this short database transaction ends; no HTTP call holds it.
  perform pg_advisory_xact_lock(923004, 5);
  insert into public.ai_daily_usage(usage_day) values (v_day) on conflict do nothing;
  select reserved_total into v_total from public.ai_daily_usage where usage_day = v_day for update;

  if exists (select 1 from public.ai_control_requests where status = 'uncertain') then
    raise exception 'An AI request is unresolved';
  end if;
  if exists (
    select 1 from public.ai_control_requests
    where product_id = p_product_id and status = 'reserved'
  ) then
    raise exception 'This product already has an AI request in progress';
  end if;
  if (select count(*) from public.ai_control_requests where status = 'reserved') >= 5 then
    raise exception 'AI concurrent request limit reached';
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

revoke all on function public.reserve_ai_control_request(uuid,uuid,text,integer,integer)
  from public, anon, authenticated;
grant execute on function public.reserve_ai_control_request(uuid,uuid,text,integer,integer)
  to service_role;

commit;
notify pgrst, 'reload schema';
