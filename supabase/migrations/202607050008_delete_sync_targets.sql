-- Deleting a sync target cascades its runs and target-product memberships. Also
-- recalculate affected product visibility so orphaned products leave the catalog,
-- while products shared with another active target remain visible.
create or replace function public.delete_sync_target(p_target_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_product_ids uuid[];
  v_deleted_id uuid;
begin
  select coalesce(array_agg(product_id), '{}'::uuid[])
  into v_product_ids
  from public.sync_target_products
  where target_id = p_target_id;

  delete from public.sync_targets
  where id = p_target_id
  returning id into v_deleted_id;

  if v_deleted_id is null then
    return false;
  end if;

  update public.products p
  set active = exists (
    select 1
    from public.sync_target_products stp
    where stp.product_id = p.id and stp.active
  ), updated_at = now()
  where p.id = any(v_product_ids);

  return true;
end $$;

revoke all on function public.delete_sync_target(uuid) from public, anon, authenticated;
grant execute on function public.delete_sync_target(uuid) to service_role;
