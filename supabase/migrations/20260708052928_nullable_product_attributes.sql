-- Distinguish an attribute that ABOUT YOU does not provide (null) from a
-- populated attribute. Parser freshness remains tracked independently in
-- product_detail_sync.parser_version.
alter table public.products
  alter column sizes drop default,
  alter column sizes drop not null,
  alter column other_sizes drop default,
  alter column other_sizes drop not null,
  alter column materials drop default,
  alter column materials drop not null,
  alter column patterns drop default,
  alter column patterns drop not null,
  alter column features drop default,
  alter column features drop not null,
  alter column styles drop default,
  alter column styles drop not null,
  alter column product_types drop default,
  alter column product_types drop not null;

update public.products set
  sizes = case when cardinality(sizes) = 0 then null else sizes end,
  other_sizes = case when cardinality(other_sizes) = 0 then null else other_sizes end,
  materials = case when cardinality(materials) = 0 then null else materials end,
  patterns = case when cardinality(patterns) = 0 then null else patterns end,
  features = case when cardinality(features) = 0 then null else features end,
  styles = case when cardinality(styles) = 0 then null else styles end,
  product_types = case when cardinality(product_types) = 0 then null else product_types end
where cardinality(sizes) = 0
   or cardinality(other_sizes) = 0
   or cardinality(materials) = 0
   or cardinality(patterns) = 0
   or cardinality(features) = 0
   or cardinality(styles) = 0
   or cardinality(product_types) = 0;

create or replace function public.null_empty_product_attributes() returns trigger
language plpgsql set search_path = public as $$
begin
  if cardinality(new.sizes) = 0 then new.sizes := null; end if;
  if cardinality(new.other_sizes) = 0 then new.other_sizes := null; end if;
  if cardinality(new.materials) = 0 then new.materials := null; end if;
  if cardinality(new.patterns) = 0 then new.patterns := null; end if;
  if cardinality(new.features) = 0 then new.features := null; end if;
  if cardinality(new.styles) = 0 then new.styles := null; end if;
  if cardinality(new.product_types) = 0 then new.product_types := null; end if;
  return new;
end $$;

drop trigger if exists zz_products_null_empty_attributes on public.products;
create trigger zz_products_null_empty_attributes
before insert or update of sizes, other_sizes, materials, patterns, features, styles, product_types
on public.products for each row execute function public.null_empty_product_attributes();

revoke all on function public.null_empty_product_attributes() from public, anon, authenticated;

-- Coverage is version-scoped: historical terminal states must not leak into
-- the current parser report. Older versions are represented only as pending.
create or replace function public.product_detail_sync_summary(p_parser_version integer)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'parserVersion', p_parser_version,
    'active', count(*),
    'complete', count(*) filter (
      where sync.status = 'complete' and sync.parser_version = p_parser_version
    ),
    'pending', count(*) filter (
      where sync.parser_version < p_parser_version
         or (sync.parser_version = p_parser_version and sync.status in ('pending', 'processing'))
    ),
    'retryable', count(*) filter (
      where sync.status = 'retryable_error' and sync.parser_version = p_parser_version
    ),
    'blockedSchema', count(*) filter (
      where sync.status = 'blocked_schema' and sync.parser_version = p_parser_version
    ),
    'sourceUnavailable', count(*) filter (
      where sync.status = 'source_unavailable' and sync.parser_version = p_parser_version
    )
  )
  from public.products product
  join public.product_detail_sync sync on sync.product_id = product.id
  where product.active;
$$;
