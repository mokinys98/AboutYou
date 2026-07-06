create table public.price_changes (
  id bigint generated always as identity primary key,
  product_id uuid not null references public.products(id) on delete cascade,
  observed_at timestamptz not null default now(),
  price integer not null check (price >= 0),
  original_price integer check (original_price >= 0),
  source_lpl_30 integer check (source_lpl_30 >= 0),
  currency char(3) not null default 'EUR'
);

create index price_changes_product_time_idx
  on public.price_changes (product_id, observed_at desc);
create index price_changes_time_idx on public.price_changes (observed_at);

-- Exact intraday transitions were not retained previously. Preserve the last known
-- observation for each historical day, then record every actual change going forward.
with historical_changes as (
  select
    d.*,
    lag(d.last_price) over (
      partition by d.product_id order by d.observed_date
    ) as previous_price
  from public.daily_prices d
)
insert into public.price_changes (
  product_id, observed_at, price, original_price, source_lpl_30, currency
)
select
  d.product_id,
  d.updated_at,
  d.last_price,
  o.original_price,
  d.source_lpl_30,
  o.currency
from historical_changes d
join public.offers o on o.product_id = d.product_id
where d.previous_price is null or d.previous_price is distinct from d.last_price;

create or replace function public.record_price_observation(
  p_product_id uuid,
  p_current_price integer,
  p_original_price integer default null,
  p_source_lpl_30 integer default null,
  p_currency char(3) default 'EUR'
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_min integer;
  v_previous_price integer;
  v_has_previous boolean;
begin
  -- Serialize observations for one product so concurrent sync runs cannot create
  -- duplicate transitions.
  perform pg_advisory_xact_lock(hashtextextended(p_product_id::text, 0));

  select current_price into v_previous_price
  from public.offers
  where product_id = p_product_id;
  v_has_previous := found;

  if not v_has_previous or v_previous_price is distinct from p_current_price then
    insert into public.price_changes(
      product_id, price, original_price, source_lpl_30, currency
    ) values (
      p_product_id, p_current_price, p_original_price, p_source_lpl_30, p_currency
    );
  end if;

  insert into public.daily_prices(product_id, observed_date, min_price, max_price, last_price, source_lpl_30)
  values (p_product_id, current_date, p_current_price, p_current_price, p_current_price, p_source_lpl_30)
  on conflict (product_id, observed_date) do update set
    min_price = least(daily_prices.min_price, excluded.min_price),
    max_price = greatest(daily_prices.max_price, excluded.max_price),
    last_price = excluded.last_price,
    source_lpl_30 = excluded.source_lpl_30,
    observations = daily_prices.observations + 1,
    updated_at = now();

  select min(min_price) into v_min from public.daily_prices
  where product_id = p_product_id and observed_date >= current_date - 29;

  insert into public.offers(product_id, current_price, original_price, source_lpl_30, observed_min_30d, currency)
  values (p_product_id, p_current_price, p_original_price, p_source_lpl_30, v_min, p_currency)
  on conflict (product_id) do update set
    current_price = excluded.current_price,
    original_price = excluded.original_price,
    source_lpl_30 = excluded.source_lpl_30,
    observed_min_30d = excluded.observed_min_30d,
    currency = excluded.currency,
    updated_at = now();
end $$;

create or replace function public.cleanup_price_history() returns bigint language sql security definer set search_path = public as $$
  with deleted_daily as (
    delete from public.daily_prices
    where observed_date < current_date - 89
    returning 1
  ), deleted_changes as (
    delete from public.price_changes
    where observed_at < now() - interval '90 days'
    returning 1
  )
  select (select count(*) from deleted_daily) + (select count(*) from deleted_changes);
$$;

alter table public.price_changes enable row level security;
revoke all on table public.price_changes from anon, authenticated;
grant all on table public.price_changes to service_role;
grant usage, select on sequence public.price_changes_id_seq to service_role;
grant execute on function public.record_price_observation(uuid, integer, integer, integer, char) to service_role;
grant execute on function public.cleanup_price_history() to service_role;
