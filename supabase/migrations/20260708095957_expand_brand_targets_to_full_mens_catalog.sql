-- Brand targets used the clothing-only landing page, so ABOUT YOU could never
-- return shoes or accessories for those brands. Keep the brand filter but let
-- the source API return the complete men's catalog. Product detail breadcrumbs
-- remain the authoritative source for category paths.
update public.sync_targets
set url = regexp_replace(
      url,
      '^https://www\.aboutyou\.lt/c/vyrams/drabuziai-20290',
      'https://www.aboutyou.lt/c/vyrams-20202'
    ),
    requested_at = now(),
    updated_at = now()
where kind = 'brand'
  and url ~ '^https://www\.aboutyou\.lt/c/vyrams/drabuziai-20290';

-- The shop page currently yields only one malformed tile. Use the same catalog
-- endpoint as every other brand so collection and breadcrumb parsing is uniform.
update public.sync_targets
set url = 'https://www.aboutyou.lt/c/vyrams-20202?brand=only-sons-6459',
    requested_at = now(),
    updated_at = now()
where kind = 'brand'
  and lower(label) = lower('Only Sons Katalogas');
