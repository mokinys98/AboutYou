-- Read-only verification for the VPS Supabase SQL Editor after
-- 20260930120000_ai_control_set.sql succeeds.
with expected_relations(name) as (
  values ('ai_control_sets'), ('ai_control_items'), ('product_ai_attributes'),
    ('ai_daily_usage'), ('ai_control_requests'), ('ai_control_pending')
), relation_checks as (
  select e.name, c.oid is not null as present,
    case when c.relkind = 'r' then c.relrowsecurity else true end as rls_enabled
  from expected_relations e
  left join pg_class c on c.oid = to_regclass('public.' || e.name)
), expected_functions(name) as (
  values ('reserve_ai_control_request'), ('finish_ai_control_request'),
    ('reconcile_ai_control_request')
), function_checks as (
  select e.name, exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = e.name
  ) as present
  from expected_functions e
)
select
  (select bool_and(present and rls_enabled) from relation_checks) as relations_and_rls_ok,
  (select bool_and(present) from function_checks) as functions_ok,
  (select count(*) from public.ai_control_sets) as control_sets,
  (select count(*) from public.ai_control_items) as control_items,
  (select count(*) from public.ai_control_requests where status in ('reserved','uncertain')) as unresolved_requests;

-- Expected immediately after a fresh migration:
-- relations_and_rls_ok = true, functions_ok = true,
-- control_sets = 0, control_items = 0, unresolved_requests = 0.
