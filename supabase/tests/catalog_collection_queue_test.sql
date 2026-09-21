-- LOCAL DISPOSABLE DATABASE ONLY. Never run this fixture on the VPS.
\set ON_ERROR_STOP on
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role; end if;
end $$;
create extension if not exists pgcrypto;
create type public.sync_target_kind as enum ('category', 'brand', 'search');
create type public.sync_run_status as enum ('running', 'success', 'partial', 'failed');
create table public.sources(id uuid primary key default gen_random_uuid());
create table public.sync_targets(
  id uuid primary key default gen_random_uuid(), source_id uuid not null references public.sources(id),
  kind public.sync_target_kind not null default 'category', label text not null, url text not null,
  enabled boolean not null default true, priority integer not null default 100, requested_at timestamptz,
  last_started_at timestamptz, last_success_at timestamptz, last_error text, updated_at timestamptz not null default now()
);
create table public.sync_runs(id uuid primary key default gen_random_uuid(), target_id uuid not null references public.sync_targets(id), status public.sync_run_status not null default 'running', pages_count integer not null default 0, products_count integer not null default 0, error text, finished_at timestamptz);
create table public.sync_target_products(target_id uuid not null, product_id uuid not null, last_seen_run_id uuid, primary key(target_id, product_id));
create table public.fixture_products(source_id uuid not null, external_id text not null, id uuid not null default gen_random_uuid(), primary key(source_id, external_id));
create or replace function public.record_catalog_batch(p_source_id uuid, p_target_id uuid, p_run_id uuid, p_products jsonb)
returns integer language plpgsql as $$ declare v_item jsonb; v_id uuid; v_count integer := 0; begin
  for v_item in select value from jsonb_array_elements(p_products) loop
    insert into public.fixture_products(source_id, external_id) values (p_source_id, v_item->>'externalId')
    on conflict (source_id, external_id) do update set external_id = excluded.external_id returning id into v_id;
    insert into public.sync_target_products(target_id, product_id, last_seen_run_id) values (p_target_id, v_id, p_run_id)
    on conflict (target_id, product_id) do update set last_seen_run_id = excluded.last_seen_run_id;
    v_count := v_count + 1;
  end loop; return v_count; end $$;
create or replace function public.finish_sync_run(p_run_id uuid, p_status public.sync_run_status, p_pages_count integer, p_products_count integer, p_error text default null)
returns void language sql as $$ update public.sync_runs set status=p_status, pages_count=p_pages_count, products_count=p_products_count, error=p_error, finished_at=now() where id=p_run_id $$;

\ir ../migrations/20260921122000_add_catalog_collection_queue.sql

do $$
declare v_source uuid := gen_random_uuid(); v_target uuid := gen_random_uuid(); v_first record; v_reclaimed record; v_saved integer; v_status public.catalog_task_status;
begin
  insert into public.sources(id) values (v_source);
  insert into public.sync_targets(id, source_id, label, url) values (v_target, v_source, 'Fixture', 'https://www.aboutyou.lt/c/vyrams-20202');
  select * into v_first from public.claim_catalog_collection_task();
  if v_first.task_id is null then raise exception 'No queue task was claimed'; end if;
  if exists (select 1 from public.claim_catalog_collection_task()) then raise exception 'Task was leased twice'; end if;
  update public.catalog_collection_tasks set lease_until = now() - interval '1 second' where id = v_first.task_id;
  select * into v_reclaimed from public.claim_catalog_collection_task();
  if v_reclaimed.lease_token = v_first.lease_token then raise exception 'Expired lease was reused'; end if;
  select public.record_catalog_collection_page(v_reclaimed.task_id, v_reclaimed.lease_token, 1, 'products-1-60000',
    (select jsonb_agg(jsonb_build_object('externalId', value::text)) from generate_series(1, 60000) value)) into v_saved;
  if v_saved <> 60000 then raise exception 'Expected 60000 saved products, got %', v_saved; end if;
  if public.record_catalog_collection_page(v_reclaimed.task_id, v_reclaimed.lease_token, 1, 'products-1-60000', '[]') <> 0 then raise exception 'Duplicate page was not idempotent'; end if;
  begin
    perform public.record_catalog_collection_page(v_reclaimed.task_id, v_first.lease_token, 2, 'stale-lease-page', '[]');
    raise exception 'Stale lease was accepted';
  exception when raise_exception then if sqlerrm <> 'Catalog task lease is missing or expired' then raise; end if; end;
  select public.finish_catalog_collection_task(v_reclaimed.task_id, v_reclaimed.lease_token, true, 60000, 60000, 1, null) into v_status;
  if v_status <> 'completed' then raise exception 'Task did not complete'; end if;
  if not exists (select 1 from public.catalog_sync_cycles where target_id=v_target and status='success') then raise exception 'Cycle did not complete'; end if;
  if not exists (select 1 from public.sync_runs where target_id=v_target and status='success' and products_count=60000) then raise exception 'Run was not reconciled once'; end if;
end $$;
select 'catalog collection queue passed' as result;
