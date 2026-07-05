-- An empty scrape is a collection failure, not evidence that every product
-- disappeared. Never let it advance missing-run counters or deactivate items.
create or replace function public.finish_sync_run(
  p_run_id uuid,
  p_status public.sync_run_status,
  p_pages_count integer,
  p_products_count integer,
  p_error text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_target_id uuid;
begin
  select target_id into v_target_id from public.sync_runs where id = p_run_id;

  if p_status = 'success' and p_products_count = 0 then
    p_status := 'failed';
    p_error := coalesce(p_error, 'Tuščias rinkimas negali būti pažymėtas sėkmingu.');
  end if;

  update public.sync_runs set status = p_status, finished_at = now(), pages_count = p_pages_count,
    products_count = p_products_count, error = p_error where id = p_run_id;

  if p_status = 'success' then
    update public.sync_target_products set
      missing_successful_runs = case when last_seen_run_id = p_run_id then 0 else missing_successful_runs + 1 end,
      active = case when last_seen_run_id = p_run_id then true else missing_successful_runs + 1 < 2 end
    where target_id = v_target_id;

    update public.products p set active = exists (
      select 1 from public.sync_target_products stp where stp.product_id = p.id and stp.active
    ) where exists (
      select 1 from public.sync_target_products x where x.product_id = p.id and x.target_id = v_target_id
    );

    update public.sync_targets set last_success_at = now(), last_error = null, requested_at = null, updated_at = now()
    where id = v_target_id;
  else
    update public.sync_targets set last_error = p_error, updated_at = now() where id = v_target_id;
  end if;
end $$;

grant execute on function public.finish_sync_run(uuid, public.sync_run_status, integer, integer, text) to service_role;
