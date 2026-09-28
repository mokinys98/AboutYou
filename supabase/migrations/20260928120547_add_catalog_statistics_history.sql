create table public.catalog_statistics_snapshots (
  observed_on date primary key default current_date,
  captured_at timestamptz not null default now(),
  catalog_products integer not null check (catalog_products >= 0),
  active_products integer not null check (active_products >= 0),
  enabled_targets integer not null check (enabled_targets >= 0)
);

create table public.catalog_target_statistics_snapshots (
  observed_on date not null,
  target_id uuid not null,
  target_label text not null,
  expected_total integer check (expected_total is null or expected_total >= 0),
  catalog_products integer not null check (catalog_products >= 0),
  primary key (observed_on, target_id)
);

create index catalog_target_statistics_target_date_idx
  on public.catalog_target_statistics_snapshots (target_id, observed_on desc);

alter table public.catalog_statistics_snapshots enable row level security;
alter table public.catalog_target_statistics_snapshots enable row level security;

revoke all on table public.catalog_statistics_snapshots from public, anon, authenticated;
revoke all on table public.catalog_target_statistics_snapshots from public, anon, authenticated;
grant select, insert, update on table public.catalog_statistics_snapshots to service_role;
grant select, insert, update, delete on table public.catalog_target_statistics_snapshots to service_role;

create or replace function public.catalog_statistics_current()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with target_counts as (
    select
      target.id,
      target.label,
      target.expected_total,
      target.last_success_at,
      count(product.id)::integer as catalog_products
    from public.sync_targets target
    left join public.sync_target_products membership
      on membership.target_id = target.id
     and membership.active
    left join public.catalog_items_read product
      on product.id = membership.product_id
    where target.enabled
    group by target.id, target.label, target.expected_total, target.last_success_at
  )
  select jsonb_build_object(
    'catalogProducts', (select count(*)::integer from public.catalog_items_read),
    'activeProducts', (select count(*)::integer from public.products where active),
    'enabledTargets', (select count(*)::integer from public.sync_targets where enabled),
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', target_counts.id,
        'label', target_counts.label,
        'expectedTotal', target_counts.expected_total,
        'catalogProducts', target_counts.catalog_products,
        'lastSuccessAt', target_counts.last_success_at
      ) order by
        case when target_counts.expected_total is null then 2
             when target_counts.catalog_products < target_counts.expected_total then 0
             else 1 end,
        coalesce(target_counts.expected_total - target_counts.catalog_products, 0) desc,
        target_counts.label
      )
      from target_counts
    ), '[]'::jsonb)
  );
$$;

create or replace function public.capture_catalog_statistics_snapshot()
returns date
language plpgsql
security invoker
set search_path = ''
as $$
declare
  snapshot_date date := current_date;
begin
  insert into public.catalog_statistics_snapshots (
    observed_on,
    captured_at,
    catalog_products,
    active_products,
    enabled_targets
  )
  select
    snapshot_date,
    now(),
    (select count(*)::integer from public.catalog_items_read),
    (select count(*)::integer from public.products where active),
    (select count(*)::integer from public.sync_targets where enabled)
  on conflict (observed_on) do update set
    captured_at = excluded.captured_at,
    catalog_products = excluded.catalog_products,
    active_products = excluded.active_products,
    enabled_targets = excluded.enabled_targets;

  delete from public.catalog_target_statistics_snapshots
  where observed_on = snapshot_date;

  insert into public.catalog_target_statistics_snapshots (
    observed_on,
    target_id,
    target_label,
    expected_total,
    catalog_products
  )
  select
    snapshot_date,
    target.id,
    target.label,
    target.expected_total,
    count(product.id)::integer
  from public.sync_targets target
  left join public.sync_target_products membership
    on membership.target_id = target.id
   and membership.active
  left join public.catalog_items_read product
    on product.id = membership.product_id
  where target.enabled
  group by target.id, target.label, target.expected_total;

  return snapshot_date;
end;
$$;

revoke all on function public.catalog_statistics_current() from public, anon, authenticated;
revoke all on function public.capture_catalog_statistics_snapshot() from public, anon, authenticated;
grant execute on function public.catalog_statistics_current() to service_role;
grant execute on function public.capture_catalog_statistics_snapshot() to service_role;

select public.capture_catalog_statistics_snapshot();

notify pgrst, 'reload schema';
