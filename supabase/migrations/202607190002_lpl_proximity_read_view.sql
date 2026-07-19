-- Keep the LPL proximity calculation inside Postgres. This avoids putting a
-- potentially huge list of matching product IDs into a PostgREST URL.
create or replace view public.catalog_items_read_with_lpl as
select i.*,
  case
    when i.source_lpl_30 is not null and i.source_lpl_30 > 0
      then i.current_price * 100.0 / i.source_lpl_30
    else null
  end as lpl_price_ratio
from public.catalog_items_read i;

revoke all on table public.catalog_items_read_with_lpl from public, anon, authenticated;
grant select on table public.catalog_items_read_with_lpl to service_role;
