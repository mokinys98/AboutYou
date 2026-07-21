-- Return products whose current price is within the selected percentage above
-- their own source LPL. Prices are stored as integer euro cents.
create or replace function public.catalog_products_near_lpl(p_proximity_pct integer)
returns table (id uuid)
language sql stable security definer set search_path = public
as $$
  select i.id
  from public.catalog_items_read i
  where p_proximity_pct between 0 and 15
    and i.source_lpl_30 is not null
    and i.source_lpl_30 > 0
    and i.current_price <= i.source_lpl_30 * (100 + p_proximity_pct) / 100;
$$;

revoke all on function public.catalog_products_near_lpl(integer) from public, anon, authenticated;
grant execute on function public.catalog_products_near_lpl(integer) to service_role;
