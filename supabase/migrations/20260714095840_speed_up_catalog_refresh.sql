create or replace function public.refresh_catalog_items_read() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pg_advisory_xact_lock(hashtext('catalog_items_read_refresh'));
  execute 'refresh materialized view concurrently public.catalog_items_read';
  -- The expanded facet relation takes far longer to diff concurrently than to
  -- rebuild. Existing JSON cache remains readable while this short refresh runs.
  execute 'refresh materialized view public.catalog_item_facet_values_read';
  delete from public.catalog_facets_cache;
  insert into public.catalog_facets_cache(filters, payload)
  values ('{}'::jsonb, public.catalog_facets('{}'::jsonb));
end;
$$;

revoke all on function public.refresh_catalog_items_read() from public, anon, authenticated;
grant execute on function public.refresh_catalog_items_read() to service_role;
