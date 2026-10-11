-- Keep catalog materialized-view dead tuples and planner statistics under control.
-- PostgreSQL's default 20% vacuum / 10% analyze scale factors are too high
-- for these frequently refreshed relations, especially while reltuples is stale.
-- This does not replace the one-time catch-up refresh or guarantee a 5-minute run.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

do $$
declare
  v_name text;
  v_owner text;
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;

  for v_name, v_owner in
    select c.relname, pg_get_userbyid(c.relowner)
    from pg_class c
    where c.oid in (
      'public.catalog_items_read'::regclass,
      'public.catalog_item_facet_values_read'::regclass
    )
      and c.relkind = 'm'
  loop
    if v_owner <> current_user then
      raise exception 'Materialized view % is owned by %, not %',
        v_name, v_owner, current_user;
    end if;
  end loop;
end;
$$;

alter materialized view public.catalog_items_read set (
  autovacuum_vacuum_threshold = 500,
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_threshold = 500,
  autovacuum_analyze_scale_factor = 0.02
);

alter materialized view public.catalog_item_facet_values_read set (
  autovacuum_vacuum_threshold = 500,
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_threshold = 500,
  autovacuum_analyze_scale_factor = 0.02
);

commit;
