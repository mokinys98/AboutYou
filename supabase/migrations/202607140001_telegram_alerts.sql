create table public.telegram_connections (
  user_id uuid primary key references public.team_members(user_id) on delete cascade,
  telegram_user_id bigint not null unique,
  chat_id bigint not null unique,
  username text,
  status text not null default 'connected' check (status in ('connected', 'blocked', 'disconnected')),
  last_error text,
  linked_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.telegram_link_tokens (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid not null references public.team_members(user_id) on delete cascade,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create index telegram_link_tokens_user_idx on public.telegram_link_tokens(user_id, created_at desc);
create index telegram_link_tokens_expiry_idx on public.telegram_link_tokens(expires_at) where used_at is null;

create table public.alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.team_members(user_id) on delete cascade,
  kind text not null check (kind in ('filter', 'product')),
  name text not null check (char_length(trim(name)) between 1 and 120),
  enabled boolean not null default true,
  product_id uuid references public.products(id) on delete cascade,
  filters jsonb,
  filter_fingerprint text,
  conditions jsonb not null,
  state jsonb not null default '{}'::jsonb,
  last_evaluated_at timestamptz not null default now(),
  last_triggered_at timestamptz,
  last_delivery_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (kind = 'product' and product_id is not null and filters is null and filter_fingerprint is null)
    or (kind = 'filter' and product_id is null and filters is not null and filter_fingerprint is not null)
  )
);

create unique index alerts_user_product_idx on public.alerts(user_id, product_id) where kind = 'product';
create unique index alerts_user_filter_idx on public.alerts(user_id, filter_fingerprint) where kind = 'filter';
create index alerts_user_idx on public.alerts(user_id);
create index alerts_product_idx on public.alerts(product_id) where product_id is not null;
create index alerts_enabled_eval_idx on public.alerts(enabled, last_evaluated_at, id);

create table public.telegram_notification_outbox (
  id uuid primary key default gen_random_uuid(),
  alert_id uuid not null references public.alerts(id) on delete cascade,
  user_id uuid not null references public.team_members(user_id) on delete cascade,
  event_key text not null unique,
  payload jsonb not null,
  status text not null default 'pending' check (status in ('pending', 'processing', 'sent', 'dead')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  telegram_message_ids jsonb,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  updated_at timestamptz not null default now()
);

create index telegram_outbox_claim_idx on public.telegram_notification_outbox(next_attempt_at, created_at)
  where status in ('pending', 'processing');
create index telegram_outbox_alert_idx on public.telegram_notification_outbox(alert_id);
create index telegram_outbox_user_idx on public.telegram_notification_outbox(user_id);
create index if not exists product_watches_product_idx on public.product_watches(product_id);

create table public.telegram_updates (
  update_id bigint primary key,
  processed_at timestamptz not null default now()
);

alter table public.telegram_connections enable row level security;
alter table public.telegram_link_tokens enable row level security;
alter table public.alerts enable row level security;
alter table public.telegram_notification_outbox enable row level security;
alter table public.telegram_updates enable row level security;

revoke all on public.telegram_connections, public.telegram_link_tokens, public.alerts,
  public.telegram_notification_outbox, public.telegram_updates from public, anon, authenticated;
grant all on public.telegram_connections, public.telegram_link_tokens, public.alerts,
  public.telegram_notification_outbox, public.telegram_updates to service_role;

create or replace function public.current_product_alert_state(p_product_id uuid)
returns jsonb language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'active', product.active,
    'currentPrice', offer.current_price,
    'belowObserved30d', offer.observed_min_30d is not null and offer.current_price <= offer.observed_min_30d,
    'belowSourceLpl30d', offer.source_lpl_30 is not null and offer.current_price <= offer.source_lpl_30,
    'sizes', coalesce((
      select jsonb_object_agg(size.external_id, size.selectable)
      from public.product_size_options size where size.product_id = product.id
    ), '{}'::jsonb)
  )
  from public.products product
  join public.offers offer on offer.product_id = product.id
  where product.id = p_product_id
$$;

create or replace function public.set_product_watch(
  p_user_id uuid,
  p_product_id uuid,
  p_watched boolean
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_product public.products%rowtype;
  v_alert_id uuid;
begin
  select * into v_product from public.products where id = p_product_id;
  if not found then raise exception 'Product not found'; end if;

  if p_watched then
    insert into public.product_watches(user_id, product_id)
    values (p_user_id, p_product_id) on conflict do nothing;

    insert into public.alerts(user_id, kind, name, product_id, conditions, state)
    values (
      p_user_id, 'product', left(coalesce(nullif(trim(v_product.brand || ' ' || v_product.name), ''), v_product.name), 120), p_product_id,
      '{"belowObserved30d":true,"belowSourceLpl30d":true,"backInCatalog":true,"sizeOptions":[]}'::jsonb,
      public.current_product_alert_state(p_product_id)
    )
    on conflict (user_id, product_id) where kind = 'product'
    do update set enabled = true, updated_at = now()
    returning id into v_alert_id;
    return jsonb_build_object('watched', true, 'alertId', v_alert_id);
  end if;

  delete from public.alerts where user_id = p_user_id and product_id = p_product_id and kind = 'product';
  delete from public.product_watches where user_id = p_user_id and product_id = p_product_id;
  return jsonb_build_object('watched', false, 'alertId', null);
end $$;

create or replace function public.consume_telegram_link_token(
  p_token_hash text,
  p_telegram_user_id bigint,
  p_chat_id bigint,
  p_username text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_user_id uuid;
begin
  select user_id into v_user_id
  from public.telegram_link_tokens
  where token_hash = p_token_hash and used_at is null and expires_at > now()
  for update;
  if not found then return null; end if;

  if exists (
    select 1 from public.telegram_connections
    where telegram_user_id = p_telegram_user_id and user_id <> v_user_id and status <> 'disconnected'
  ) then raise exception 'Telegram account is already linked'; end if;

  update public.telegram_link_tokens set used_at = now() where token_hash = p_token_hash;
  insert into public.telegram_connections(user_id, telegram_user_id, chat_id, username, status, last_error, linked_at, updated_at)
  values (v_user_id, p_telegram_user_id, p_chat_id, nullif(trim(p_username), ''), 'connected', null, now(), now())
  on conflict (user_id) do update set
    telegram_user_id = excluded.telegram_user_id, chat_id = excluded.chat_id,
    username = excluded.username, status = 'connected', last_error = null, linked_at = now(), updated_at = now();
  return v_user_id;
end $$;

create or replace function public.evaluate_telegram_alerts(p_limit integer default 100)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_alert public.alerts%rowtype;
  v_now timestamptz := now();
  v_current jsonb;
  v_triggers jsonb;
  v_products jsonb;
  v_count integer;
  v_enqueued integer := 0;
  v_connected boolean;
  v_size jsonb;
begin
  if p_limit < 1 or p_limit > 1000 then raise exception 'Invalid alert limit'; end if;
  if not pg_try_advisory_xact_lock(784512093) then return 0; end if;

  for v_alert in
    select * from public.alerts where enabled order by last_evaluated_at, id limit p_limit for update skip locked
  loop
    select exists(select 1 from public.telegram_connections c where c.user_id = v_alert.user_id and c.status = 'connected')
      into v_connected;

    if v_alert.kind = 'filter' then
      select coalesce(max(total_count), 0), coalesce(jsonb_agg(product_payload order by first_seen_at desc), '[]'::jsonb)
      into v_count, v_products
      from (
        select item.first_seen_at, count(*) over () as total_count, jsonb_build_object(
          'id', item.id, 'name', item.name, 'brand', item.brand,
          'currentPrice', item.current_price, 'originalPrice', item.original_price,
          'currency', item.currency, 'imageUrls', item.image_urls,
          'firstSeenAt', item.first_seen_at
        ) as product_payload
        from public.catalog_items item
        where item.first_seen_at > v_alert.last_evaluated_at and item.first_seen_at <= v_now
          and public.catalog_item_matches(item, case
            when nullif(v_alert.filters->>'categoryPath', '') is not null
              then jsonb_set(v_alert.filters, '{categories}', jsonb_build_array(v_alert.filters->>'categoryPath'), true)
            else v_alert.filters end)
        order by item.first_seen_at desc limit 100
      ) matches;

      if v_count > 0 and v_connected then
        insert into public.telegram_notification_outbox(alert_id, user_id, event_key, payload)
        values (v_alert.id, v_alert.user_id, v_alert.id::text || ':filter:' || extract(epoch from v_now)::bigint,
          jsonb_build_object('kind','filter','alertId',v_alert.id,'name',v_alert.name,'filters',v_alert.filters,
            'triggers',jsonb_build_array('newMatches'),'totalCount',v_count,'products',v_products))
        on conflict (event_key) do nothing;
        if found then v_enqueued := v_enqueued + 1; end if;
      end if;
    else
      v_current := public.current_product_alert_state(v_alert.product_id);
      if v_current is null then
        update public.alerts set last_evaluated_at = v_now, updated_at = v_now where id = v_alert.id;
        continue;
      end if;
      v_triggers := '[]'::jsonb;
      if v_alert.conditions ? 'priceBelow'
         and (v_alert.state->>'currentPrice')::integer > (v_alert.conditions->>'priceBelow')::integer
         and (v_current->>'currentPrice')::integer <= (v_alert.conditions->>'priceBelow')::integer then
        v_triggers := v_triggers || '"priceBelow"'::jsonb;
      end if;
      if coalesce((v_alert.conditions->>'belowObserved30d')::boolean, false)
         and not coalesce((v_alert.state->>'belowObserved30d')::boolean, false)
         and coalesce((v_current->>'belowObserved30d')::boolean, false) then
        v_triggers := v_triggers || '"belowObserved30d"'::jsonb;
      end if;
      if coalesce((v_alert.conditions->>'belowSourceLpl30d')::boolean, false)
         and not coalesce((v_alert.state->>'belowSourceLpl30d')::boolean, false)
         and coalesce((v_current->>'belowSourceLpl30d')::boolean, false) then
        v_triggers := v_triggers || '"belowSourceLpl30d"'::jsonb;
      end if;
      if coalesce((v_alert.conditions->>'backInCatalog')::boolean, false)
         and not coalesce((v_alert.state->>'active')::boolean, false)
         and coalesce((v_current->>'active')::boolean, false) then
        v_triggers := v_triggers || '"backInCatalog"'::jsonb;
      end if;
      for v_size in select value from jsonb_array_elements(coalesce(v_alert.conditions->'sizeOptions', '[]'::jsonb)) loop
        if not coalesce((v_alert.state->'sizes'->>(v_size->>'id'))::boolean, false)
           and coalesce((v_current->'sizes'->>(v_size->>'id'))::boolean, false) then
          v_triggers := v_triggers || jsonb_build_array('size:' || (v_size->>'label'));
        end if;
      end loop;

      if jsonb_array_length(v_triggers) > 0 and v_connected then
        select jsonb_build_array(jsonb_build_object(
          'id', product.id, 'name', product.name, 'brand', product.brand,
          'currentPrice', offer.current_price, 'originalPrice', offer.original_price,
          'currency', offer.currency, 'imageUrls', product.image_urls,
          'previousPrice', nullif(v_alert.state->>'currentPrice','')::integer
        )) into v_products
        from public.products product join public.offers offer on offer.product_id = product.id
        where product.id = v_alert.product_id;
        insert into public.telegram_notification_outbox(alert_id, user_id, event_key, payload)
        values (v_alert.id, v_alert.user_id,
          v_alert.id::text || ':product:' || md5(v_triggers::text || v_current::text || v_now::text),
          jsonb_build_object('kind','product','alertId',v_alert.id,'name',v_alert.name,
            'triggers',v_triggers,'totalCount',1,'products',v_products))
        on conflict (event_key) do nothing;
        if found then v_enqueued := v_enqueued + 1; end if;
      end if;
      update public.alerts set state = v_current where id = v_alert.id;
    end if;

    update public.alerts set last_evaluated_at = v_now, updated_at = v_now where id = v_alert.id;
  end loop;
  return v_enqueued;
end $$;

create or replace function public.claim_telegram_notifications(p_limit integer default 20, p_lease_minutes integer default 5)
returns table(id uuid, alert_id uuid, user_id uuid, payload jsonb, chat_id bigint, lease_token uuid, attempts integer)
language plpgsql security definer set search_path = public as $$
declare v_lease uuid := gen_random_uuid();
begin
  if p_limit < 1 or p_limit > 100 or p_lease_minutes < 1 or p_lease_minutes > 30 then
    raise exception 'Invalid notification claim parameters';
  end if;
  return query
  with candidates as (
    select queue.id
    from public.telegram_notification_outbox queue
    join public.telegram_connections connection on connection.user_id = queue.user_id and connection.status = 'connected'
    where queue.next_attempt_at <= now()
      and (queue.status = 'pending' or (queue.status = 'processing' and queue.lease_until < now()))
    order by queue.created_at limit p_limit for update of queue skip locked
  ), claimed as (
    update public.telegram_notification_outbox queue set
      status = 'processing', lease_token = v_lease, lease_until = now() + make_interval(mins => p_lease_minutes),
      attempts = queue.attempts + 1, updated_at = now()
    from candidates where queue.id = candidates.id
    returning queue.*
  )
  select claimed.id, claimed.alert_id, claimed.user_id, claimed.payload, connection.chat_id,
    claimed.lease_token, claimed.attempts
  from claimed join public.telegram_connections connection on connection.user_id = claimed.user_id;
end $$;

create or replace function public.complete_telegram_notification(
  p_id uuid, p_lease_token uuid, p_message_ids jsonb
) returns void language plpgsql security definer set search_path = public as $$
begin
  update public.telegram_notification_outbox set status='sent', sent_at=now(), telegram_message_ids=p_message_ids,
    lease_token=null, lease_until=null, last_error=null, updated_at=now()
  where id=p_id and status='processing' and lease_token=p_lease_token;
  if not found then raise exception 'Notification lease is missing'; end if;
  update public.alerts alert set last_triggered_at=now(), last_delivery_error=null, updated_at=now()
  from public.telegram_notification_outbox queue where queue.id=p_id and alert.id=queue.alert_id;
end $$;

create or replace function public.fail_telegram_notification(
  p_id uuid, p_lease_token uuid, p_error text, p_retry_after_seconds integer default null, p_permanent boolean default false
) returns void language plpgsql security definer set search_path = public as $$
declare v_user_id uuid; v_attempts integer;
begin
  select user_id, attempts into v_user_id, v_attempts from public.telegram_notification_outbox
  where id=p_id and status='processing' and lease_token=p_lease_token for update;
  if not found then raise exception 'Notification lease is missing'; end if;
  update public.telegram_notification_outbox set
    status=case when p_permanent or v_attempts >= 6 then 'dead' else 'pending' end,
    next_attempt_at=case when p_permanent then next_attempt_at else now() + make_interval(secs => coalesce(p_retry_after_seconds, least(3600, 30 * (2 ^ greatest(v_attempts-1,0))))) end,
    lease_token=null, lease_until=null, last_error=left(p_error,1000), updated_at=now()
  where id=p_id;
  update public.alerts alert set last_delivery_error=left(p_error,1000), updated_at=now()
  from public.telegram_notification_outbox queue where queue.id=p_id and alert.id=queue.alert_id;
  if p_permanent then
    update public.telegram_connections set status='blocked', last_error=left(p_error,1000), updated_at=now()
    where user_id=v_user_id;
  end if;
end $$;

revoke all on function public.current_product_alert_state(uuid) from public, anon, authenticated;
revoke all on function public.set_product_watch(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.consume_telegram_link_token(text, bigint, bigint, text) from public, anon, authenticated;
revoke all on function public.evaluate_telegram_alerts(integer) from public, anon, authenticated;
revoke all on function public.claim_telegram_notifications(integer, integer) from public, anon, authenticated;
revoke all on function public.complete_telegram_notification(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.fail_telegram_notification(uuid, uuid, text, integer, boolean) from public, anon, authenticated;
grant execute on function public.current_product_alert_state(uuid) to service_role;
grant execute on function public.set_product_watch(uuid, uuid, boolean) to service_role;
grant execute on function public.consume_telegram_link_token(text, bigint, bigint, text) to service_role;
grant execute on function public.evaluate_telegram_alerts(integer) to service_role;
grant execute on function public.claim_telegram_notifications(integer, integer) to service_role;
grant execute on function public.complete_telegram_notification(uuid, uuid, jsonb) to service_role;
grant execute on function public.fail_telegram_notification(uuid, uuid, text, integer, boolean) to service_role;
