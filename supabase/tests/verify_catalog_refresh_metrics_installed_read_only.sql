-- Run in VPS Supabase SQL Editor after applying the metrics migration.
-- Expected on this VPS: one row; all *_installed / *_records_* and
-- reader_can_select_* columns true; exposed_to_* false.
-- Counts are initially zero and grow only after actual refresh invocations.
begin read only;
set local statement_timeout = '5s';

select
  to_regclass('public.catalog_refresh_runs') is not null as run_table_installed,
  to_regclass('public.catalog_refresh_phases') is not null as phase_table_installed,
  to_regprocedure('public.record_catalog_refresh_phase(bigint,text,timestamptz,bigint,text,text)') is not null as phase_writer_installed,
  position('catalog_refresh_runs' in pg_get_functiondef('public.process_catalog_items_read_refresh()'::regprocedure)) > 0 as process_records_runs,
  position('record_catalog_refresh_phase' in pg_get_functiondef('public.rebuild_catalog_items_read_internal()'::regprocedure)) > 0 as rebuild_records_phases,
  position('record_catalog_refresh_phase' in pg_get_functiondef('public.invalidate_catalog_facets_cache()'::regprocedure)) > 0 as cache_phase_records_phases,
  has_table_privilege('anon', 'public.catalog_refresh_runs', 'SELECT') as exposed_to_anon,
  has_table_privilege('authenticated', 'public.catalog_refresh_runs', 'SELECT') as exposed_to_authenticated,
  has_table_privilege('service_role', 'public.catalog_refresh_runs', 'SELECT') as exposed_to_service_role,
  has_table_privilege('codex_reader', 'public.catalog_refresh_runs', 'SELECT') as reader_can_select_runs,
  has_table_privilege('codex_reader', 'public.catalog_refresh_phases', 'SELECT') as reader_can_select_phases,
  (select count(*) from public.catalog_refresh_runs) as recorded_runs,
  (select count(*) from public.catalog_refresh_phases) as recorded_phases;

rollback;
