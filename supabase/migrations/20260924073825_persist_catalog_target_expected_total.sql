-- Keep the latest root source total on the editable sync group. This is a
-- planning hint for splitting oversized groups; task-level totals remain the
-- authoritative per-cycle completion values.
alter table public.sync_targets
  add column if not exists expected_total integer
  check (expected_total is null or expected_total >= 0);

comment on column public.sync_targets.expected_total is
  'Latest source-reported expectedTotal from this target root collection.';

with latest_root_total as (
  select distinct on (cycle.target_id)
    cycle.target_id,
    task.expected_total
  from public.catalog_collection_tasks task
  join public.catalog_sync_cycles cycle on cycle.id = task.cycle_id
  join public.catalog_target_parts part on part.id = task.part_id
  where part.part_key = 'root'
    and task.expected_total is not null
  order by cycle.target_id, task.updated_at desc, task.id desc
)
update public.sync_targets target
set expected_total = latest.expected_total
from latest_root_total latest
where target.id = latest.target_id
  and target.expected_total is distinct from latest.expected_total;

create or replace function public.persist_catalog_target_expected_total()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare
  v_target_id uuid;
begin
  if new.expected_total is null or new.expected_total is not distinct from old.expected_total then
    return new;
  end if;

  select cycle.target_id into v_target_id
  from public.catalog_sync_cycles cycle
  join public.catalog_target_parts part on part.id = new.part_id
  where cycle.id = new.cycle_id
    and part.part_key = 'root';

  if v_target_id is not null then
    update public.sync_targets
    set expected_total = new.expected_total,
        updated_at = now()
    where id = v_target_id
      and expected_total is distinct from new.expected_total;
  end if;
  return new;
end;
$$;

revoke all on function public.persist_catalog_target_expected_total()
  from public, anon, authenticated;

drop trigger if exists catalog_tasks_persist_target_expected_total
  on public.catalog_collection_tasks;
create trigger catalog_tasks_persist_target_expected_total
after update of expected_total on public.catalog_collection_tasks
for each row execute function public.persist_catalog_target_expected_total();

notify pgrst, 'reload schema';
