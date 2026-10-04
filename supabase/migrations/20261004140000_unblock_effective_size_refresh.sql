-- The cron refresh repeatedly reaches its five-minute statement timeout while
-- the effective-size membership view is being refreshed concurrently. A full
-- replacement avoids the expensive concurrent row-diff path. It can briefly
-- block readers of this view; the caller's 3-second lock timeout still applies.
-- This migration only changes the refresh function. The next scheduled cron
-- run performs the refresh and invalidates the facet cache after success.
begin;

create or replace function public.invalidate_catalog_facets_cache()
returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  execute 'refresh materialized view public.catalog_effective_size_membership_read';
  perform public.refresh_catalog_static_size_facets_cache();
  delete from public.catalog_facets_cache;
end;
$$;

commit;
