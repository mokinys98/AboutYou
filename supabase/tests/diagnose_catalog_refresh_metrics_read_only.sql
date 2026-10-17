-- VPS Supabase SQL Editor, after the catalog refresh metrics migration is
-- installed and real cycles have run. Read-only, bounded to 14 days.
-- A failed run retains its completed phase timings and failed phase after
-- the refresh transaction is rolled back by the outer handler.
begin read only;
set local statement_timeout = '10s';

select
  outcome,
  count(*) as runs_14d,
  count(*) filter (where error_sqlstate = '57014') as canceled_or_timed_out,
  round(avg(duration_ms)::numeric, 1) as avg_duration_ms,
  round(percentile_cont(0.5) within group (order by duration_ms)::numeric, 1) as p50_duration_ms,
  round(percentile_cont(0.95) within group (order by duration_ms)::numeric, 1) as p95_duration_ms,
  max(duration_ms) as max_duration_ms
from public.catalog_refresh_runs
where started_at >= clock_timestamp() - interval '14 days'
group by outcome
order by outcome;

select
  p.phase,
  count(*) as completed_phases_14d,
  round(avg(p.duration_ms)::numeric, 1) as avg_duration_ms,
  round(percentile_cont(0.5) within group (order by p.duration_ms)::numeric, 1) as p50_duration_ms,
  round(percentile_cont(0.95) within group (order by p.duration_ms)::numeric, 1) as p95_duration_ms,
  max(p.duration_ms) as max_duration_ms
from public.catalog_refresh_phases p
join public.catalog_refresh_runs r on r.run_id = p.run_id
where r.started_at >= clock_timestamp() - interval '14 days'
  and r.outcome = 'refreshed'
  and p.outcome = 'success'
group by p.phase
order by p.phase;

select
  r.run_id,
  r.started_at,
  r.completed_at,
  r.outcome,
  r.duration_ms,
  r.target_version,
  r.requested_after,
  r.failure_phase,
  r.error_sqlstate,
  count(p.phase_id) as recorded_phase_rows
from public.catalog_refresh_runs r
left join public.catalog_refresh_phases p on p.run_id = r.run_id
where r.started_at >= clock_timestamp() - interval '14 days'
group by r.run_id, r.started_at, r.completed_at, r.outcome,
  r.duration_ms, r.target_version, r.requested_after,
  r.failure_phase, r.error_sqlstate
order by r.started_at desc
limit 30;

select
  r.run_id,
  r.started_at as run_started_at,
  r.duration_ms as run_duration_ms,
  r.error_sqlstate,
  p.phase_id,
  p.phase,
  p.outcome,
  p.started_at as phase_started_at,
  p.duration_ms as phase_duration_ms
from public.catalog_refresh_runs r
join public.catalog_refresh_phases p on p.run_id = r.run_id
where r.started_at >= clock_timestamp() - interval '14 days'
  and r.outcome = 'failed'
order by r.started_at desc, p.phase_id
limit 100;

rollback;
