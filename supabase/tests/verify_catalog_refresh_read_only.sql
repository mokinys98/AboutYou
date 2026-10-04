-- Read-only snapshot of catalog refresh health before an API benchmark.
-- Expected before a stable run: requested_version = completed_version,
-- last_status is refreshed or clean, and last_error is null.
begin read only;

select
  clock_timestamp() as checked_at_utc,
  requested_version,
  completed_version,
  requested_version - completed_version as pending_versions,
  last_status,
  last_duration_ms,
  last_error,
  refresh_started_at,
  refresh_completed_at
from public.catalog_read_model_refresh_state
where singleton;

rollback;
