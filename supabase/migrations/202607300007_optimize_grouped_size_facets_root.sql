-- The first request after a facet-cache invalidation must rebuild the complete
-- payload. Self-hosted PostgREST may otherwise cancel it using the shorter
-- role-level statement timeout. Subsequent calls read catalog_facets_cache.

alter function public.catalog_facets_cached(jsonb)
  set statement_timeout = '60s';

alter function public.catalog_grouped_size_facets(jsonb)
  set statement_timeout = '60s';

notify pgrst, 'reload schema';
