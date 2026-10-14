-- Run after applying 20261011210000 in VPS SQL Editor.
-- Expected: one row; cron_active=false, function_owner=postgres,
-- uses_literal_checks=true, old_regex_checks_absent=true.
-- Also rerun verify_catalog_size_domain_predicate_equivalence_read_only.sql
-- after deployment: compared_rows > 0 and mismatched_rows = 0.
begin read only;
set local statement_timeout = '5s';

select
  j.active as cron_active,
  pg_get_userbyid(p.proowner) as function_owner,
  position('position(''džins'' in value)' in pg_get_functiondef(p.oid)) > 0
    and position('position(''marškin'' in value)' in pg_get_functiondef(p.oid)) > 0
    and position('position(''drabuž'' in value)' in pg_get_functiondef(p.oid)) > 0
    as uses_literal_checks,
  position('when value ~ ' in pg_get_functiondef(p.oid)) = 0
    as old_regex_checks_absent
from pg_proc p
cross join cron.job j
where p.oid = 'public.catalog_size_domain(text[],text[],text)'::regprocedure
  and j.jobname = 'catalog-read-model-refresh';

rollback;
