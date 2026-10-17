-- The shadow stage is for controlled SQL Editor validation only. Match the
-- production materialized view's read access while the stage remains present.
begin;
set local statement_timeout = '5s';
set local lock_timeout = '3s';

do $$
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  if not exists (
    select 1
    from pg_class c
    where c.oid = to_regclass('public.catalog_size_facets_read_optimized_stage')
      and c.relkind = 'm'
      and pg_get_userbyid(c.relowner) = current_user
  ) then
    raise exception 'Expected the optimized stage materialized view owned by postgres';
  end if;
end;
$$;

revoke all on table public.catalog_size_facets_read_optimized_stage
  from public, anon, authenticated;

commit;
