-- Run after a failed attempt to apply the refresh metrics migration.
-- Read-only: distinguish no change from partial application before retrying.
begin read only;
set local statement_timeout = '5s';

select
  clock_timestamp() as checked_at_utc,
  to_regclass('public.catalog_refresh_metrics_run_id_seq') as metrics_sequence,
  to_regclass('public.catalog_refresh_runs') as runs_table,
  to_regclass('public.catalog_refresh_phases') as phases_table,
  to_regprocedure('public.record_catalog_refresh_phase(bigint,text,timestamptz,bigint,text,text)') as phase_writer,
  (select pg_get_userbyid(p.proowner) from pg_proc p
   where p.oid = 'public.process_catalog_items_read_refresh()'::regprocedure) as process_owner,
  (select md5(lower(pg_get_functiondef(p.oid))) from pg_proc p
   where p.oid = 'public.process_catalog_items_read_refresh()'::regprocedure) as process_definition_md5,
  (select md5(lower(pg_get_functiondef(p.oid))) from pg_proc p
   where p.oid = 'public.rebuild_catalog_items_read_internal()'::regprocedure) as rebuild_definition_md5,
  (select md5(lower(pg_get_functiondef(p.oid))) from pg_proc p
   where p.oid = 'public.invalidate_catalog_facets_cache()'::regprocedure) as cache_definition_md5,
  (select count(*) = 1 and coalesce(bool_and(not active), false)
   from cron.job where jobname = 'catalog-read-model-refresh') as cron_paused,
  (select jsonb_build_object(
    'requested_version', s.requested_version,
    'completed_version', s.completed_version,
    'last_status', s.last_status,
    'last_duration_ms', s.last_duration_ms
  ) from public.catalog_read_model_refresh_state s where s.singleton) as refresh_state;

rollback;
