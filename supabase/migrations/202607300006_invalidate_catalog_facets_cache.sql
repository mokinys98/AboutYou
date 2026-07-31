-- Allow the admin Debug override API to invalidate cached facet payloads.

create or replace function public.invalidate_catalog_facets_cache()
returns void
language sql security definer
set search_path = public, pg_temp as $$
  delete from public.catalog_facets_cache;
$$;

revoke all on function public.invalidate_catalog_facets_cache() from public, anon, authenticated;
grant execute on function public.invalidate_catalog_facets_cache() to service_role;
