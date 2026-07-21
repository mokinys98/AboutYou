-- Telegram filter alerts must advance with the published read-model version,
-- not with wall-clock time while catalog base tables are being scraped.

alter table public.alerts
  add column if not exists last_evaluated_catalog_version bigint;

update public.alerts
set last_evaluated_catalog_version = coalesce(
  (select completed_version from public.catalog_read_model_refresh_state where singleton),
  0
),
last_evaluated_at = greatest(
  last_evaluated_at,
  coalesce((select refresh_started_at from public.catalog_read_model_refresh_state where singleton), now())
)
where last_evaluated_catalog_version is null;

alter table public.alerts
  alter column last_evaluated_catalog_version set default 0,
  alter column last_evaluated_catalog_version set not null;

alter table public.alerts
  drop constraint if exists alerts_last_evaluated_catalog_version_check;
alter table public.alerts
  add constraint alerts_last_evaluated_catalog_version_check
  check (last_evaluated_catalog_version >= 0);

create index if not exists alerts_enabled_catalog_version_idx
  on public.alerts(kind, enabled, last_evaluated_catalog_version, id);

-- A filter alert created or re-enabled after this migration starts from the
-- currently published snapshot. Editing its filters starts a new evaluation
-- window without requiring every API caller to know the publication version.
create or replace function public.initialize_alert_catalog_version()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp as $$
declare
  v_completed_version bigint;
begin
  select completed_version into v_completed_version
  from public.catalog_read_model_refresh_state
  where singleton;

  new.last_evaluated_catalog_version := coalesce(v_completed_version, 0);
  return new;
end;
$$;

revoke all on function public.initialize_alert_catalog_version() from public, anon, authenticated;

drop trigger if exists alerts_initialize_catalog_version on public.alerts;
create trigger alerts_initialize_catalog_version
before insert on public.alerts
for each row execute function public.initialize_alert_catalog_version();

create or replace function public.reset_filter_alert_catalog_version()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp as $$
declare
  v_completed_version bigint;
begin
  if new.kind = 'filter' and (
    new.filters is distinct from old.filters
    or (not old.enabled and new.enabled)
  ) then
    select completed_version into v_completed_version
    from public.catalog_read_model_refresh_state
    where singleton;
    new.last_evaluated_catalog_version := coalesce(v_completed_version, 0);
  end if;
  return new;
end;
$$;

revoke all on function public.reset_filter_alert_catalog_version() from public, anon, authenticated;

drop trigger if exists alerts_reset_filter_catalog_version on public.alerts;
create trigger alerts_reset_filter_catalog_version
before update on public.alerts
for each row execute function public.reset_filter_alert_catalog_version();

alter table public.telegram_notification_outbox
  add column if not exists required_catalog_version bigint;

update public.telegram_notification_outbox
set required_catalog_version = coalesce(
  (select completed_version from public.catalog_read_model_refresh_state where singleton),
  0
),
payload = case
  when payload->>'kind' = 'filter' then jsonb_set(
    payload,
    '{catalogVersion}',
    to_jsonb(coalesce((select completed_version from public.catalog_read_model_refresh_state where singleton), 0)),
    true
  )
  else payload
end
where required_catalog_version is null;

alter table public.telegram_notification_outbox
  alter column required_catalog_version set default 0,
  alter column required_catalog_version set not null;

alter table public.telegram_notification_outbox
  drop constraint if exists telegram_outbox_required_catalog_version_check;
alter table public.telegram_notification_outbox
  add constraint telegram_outbox_required_catalog_version_check
  check (required_catalog_version >= 0);

create index if not exists telegram_outbox_required_version_idx
  on public.telegram_notification_outbox(required_catalog_version, next_attempt_at, created_at)
  where status in ('pending', 'processing');

-- The read model has the same columns as catalog_items, but is a different
-- composite type. Keep matching semantics in one overload so alert evaluation
-- and the interactive catalog use the same published snapshot.
create or replace function public.catalog_item_matches(
  item public.catalog_items_read,
  filters jsonb,
  omit_group text default null
) returns boolean
language sql stable security invoker set search_path = public as $$
  select
    (omit_group = 'brands' or coalesce(jsonb_array_length(filters->'brands'), 0) = 0 or item.brand in (select jsonb_array_elements_text(filters->'brands'))) and
    (omit_group = 'brandTiers' or coalesce(jsonb_array_length(filters->'brandTiers'), 0) = 0 or item.brand_tier in (select jsonb_array_elements_text(filters->'brandTiers'))) and
    (omit_group = 'sources' or coalesce(jsonb_array_length(filters->'sources'), 0) = 0 or item.source in (select jsonb_array_elements_text(filters->'sources'))) and
    (omit_group = 'colors' or coalesce(jsonb_array_length(filters->'colors'), 0) = 0 or item.color_family in (select jsonb_array_elements_text(filters->'colors'))) and
    (omit_group = 'colorShades' or coalesce(jsonb_array_length(filters->'colorShades'), 0) = 0 or item.color_shade in (select jsonb_array_elements_text(filters->'colorShades'))) and
    (omit_group = 'categories' or coalesce(jsonb_array_length(filters->'categories'), 0) = 0 or item.categories && array(select jsonb_array_elements_text(filters->'categories'))) and
    (omit_group = 'sizes' or coalesce(jsonb_array_length(filters->'sizes'), 0) = 0 or item.sizes && array(select jsonb_array_elements_text(filters->'sizes'))) and
    (omit_group = 'otherSizes' or coalesce(jsonb_array_length(filters->'otherSizes'), 0) = 0 or item.other_sizes && array(select jsonb_array_elements_text(filters->'otherSizes'))) and
    (omit_group = 'materials' or coalesce(jsonb_array_length(filters->'materials'), 0) = 0 or item.materials && array(select jsonb_array_elements_text(filters->'materials'))) and
    (omit_group = 'patterns' or coalesce(jsonb_array_length(filters->'patterns'), 0) = 0 or item.patterns && array(select jsonb_array_elements_text(filters->'patterns'))) and
    (omit_group = 'features' or coalesce(jsonb_array_length(filters->'features'), 0) = 0 or item.features && array(select jsonb_array_elements_text(filters->'features'))) and
    (omit_group = 'styles' or coalesce(jsonb_array_length(filters->'styles'), 0) = 0 or item.styles && array(select jsonb_array_elements_text(filters->'styles'))) and
    (omit_group = 'productTypes' or coalesce(jsonb_array_length(filters->'productTypes'), 0) = 0 or item.product_types && array(select jsonb_array_elements_text(filters->'productTypes'))) and
    (omit_group = 'premium' or coalesce((filters->>'isPremium')::boolean, false) = false or item.is_premium) and
    (omit_group = 'excludeBasics' or coalesce((filters->>'excludeBasics')::boolean, false) = false or not (
      item.category_names && public.catalog_excluded_basics_categories() or
      item.categories && public.catalog_excluded_basics_categories()
    )) and
    (omit_group = 'excludeAccessories' or coalesce((filters->>'excludeAccessories')::boolean, false) = false or
      not (item.category_paths && public.catalog_excluded_accessories_paths())) and
    (omit_group = 'price' or filters->>'priceMin' is null or item.current_price >= (filters->>'priceMin')::integer) and
    (omit_group = 'price' or filters->>'priceMax' is null or item.current_price <= (filters->>'priceMax')::integer) and
    (filters->>'discountMin' is null or item.discount_pct >= (filters->>'discountMin')::numeric) and
    (coalesce((filters->>'belowObserved30d')::boolean, false) = false or
      case when filters->>'priceComparison' = 'source_lpl' then item.below_source_lpl_30d else item.below_observed_30d end) and
    (coalesce((filters->>'newOnly')::boolean, false) = false or item.first_seen_at >= now() - interval '30 days')
$$;

create or replace function public.evaluate_telegram_alerts(p_limit integer default 100)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_alert public.alerts%rowtype;
  v_now timestamptz := now();
  v_publication_cutoff timestamptz;
  v_catalog_version bigint;
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

  select completed_version, coalesce(refresh_started_at, now())
  into v_catalog_version, v_publication_cutoff
  from public.catalog_read_model_refresh_state
  where singleton;
  v_catalog_version := coalesce(v_catalog_version, 0);

  for v_alert in
    select *
    from public.alerts
    where enabled
      and (kind = 'product' or last_evaluated_catalog_version < v_catalog_version)
    order by last_evaluated_at, id
    limit p_limit
    for update skip locked
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
        from public.catalog_items_read item
        where item.first_seen_at > v_alert.last_evaluated_at
          and item.first_seen_at <= v_publication_cutoff
          and public.catalog_item_matches(item, case
            when nullif(v_alert.filters->>'categoryPath', '') is not null
              then jsonb_set(v_alert.filters, '{categories}', jsonb_build_array(v_alert.filters->>'categoryPath'), true)
            else v_alert.filters end)
        order by item.first_seen_at desc limit 100
      ) matches;

      if v_count > 0 and v_connected then
        insert into public.telegram_notification_outbox(
          alert_id, user_id, event_key, payload, required_catalog_version
        )
        values (
          v_alert.id, v_alert.user_id,
          v_alert.id::text || ':filter:' || v_catalog_version,
          jsonb_build_object('kind','filter','alertId',v_alert.id,'name',v_alert.name,
            'filters',v_alert.filters,'catalogVersion',v_catalog_version,
            'triggers',jsonb_build_array('newMatches'),'totalCount',v_count,'products',v_products),
          v_catalog_version
        )
        on conflict (event_key) do nothing;
        if found then v_enqueued := v_enqueued + 1; end if;
      end if;
      update public.alerts
      set last_evaluated_at = v_publication_cutoff,
          last_evaluated_catalog_version = v_catalog_version,
          updated_at = now()
      where id = v_alert.id;
    else
      v_current := public.current_product_alert_state(v_alert.product_id);
      if v_current is null then
        update public.alerts
        set last_evaluated_at = v_now, last_evaluated_catalog_version = v_catalog_version, updated_at = now()
        where id = v_alert.id;
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
        insert into public.telegram_notification_outbox(
          alert_id, user_id, event_key, payload, required_catalog_version
        )
        values (
          v_alert.id, v_alert.user_id,
          v_alert.id::text || ':product:' || md5(v_triggers::text || v_current::text || v_now::text),
          jsonb_build_object('kind','product','alertId',v_alert.id,'name',v_alert.name,
            'triggers',v_triggers,'totalCount',1,'products',v_products,
            'catalogVersion',v_catalog_version),
          v_catalog_version
        )
        on conflict (event_key) do nothing;
        if found then v_enqueued := v_enqueued + 1; end if;
      end if;
      update public.alerts
      set state = v_current, last_evaluated_at = v_now,
          last_evaluated_catalog_version = v_catalog_version, updated_at = now()
      where id = v_alert.id;
    end if;
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
    join public.telegram_connections connection
      on connection.user_id = queue.user_id and connection.status = 'connected'
    cross join public.catalog_read_model_refresh_state refresh_state
    where refresh_state.singleton
      and queue.required_catalog_version <= refresh_state.completed_version
      and queue.next_attempt_at <= now()
      and (queue.status = 'pending' or (queue.status = 'processing' and queue.lease_until < now()))
    order by queue.created_at
    limit p_limit for update of queue skip locked
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

revoke all on function public.catalog_item_matches(public.catalog_items_read, jsonb, text) from public, anon, authenticated;
grant execute on function public.catalog_item_matches(public.catalog_items_read, jsonb, text) to service_role;
revoke all on function public.evaluate_telegram_alerts(integer) from public, anon, authenticated;
grant execute on function public.evaluate_telegram_alerts(integer) to service_role;
revoke all on function public.claim_telegram_notifications(integer, integer) from public, anon, authenticated;
grant execute on function public.claim_telegram_notifications(integer, integer) to service_role;

notify pgrst, 'reload schema';
