-- Run in VPS Supabase SQL Editor after catch-up preflight reports a held lock.
-- Read-only: identifies sessions holding the catalog refresh advisory lock or
-- strong read-model relation locks. One NO_MATCHING_REFRESH_LOCK row is
-- returned if none are currently held.
begin read only;
set local statement_timeout = '5s';

with lock_rows as (
  select
    clock_timestamp() as checked_at_utc,
    l.pid,
    a.usename,
    a.application_name,
    a.state,
    a.wait_event_type,
    a.wait_event,
    a.xact_start,
    a.query_start,
    left(a.query, 300) as query_sample,
    l.locktype,
    case
      when l.locktype = 'advisory'
        then l.classid::text || ':' || l.objid::text || ':' || l.objsubid::text
      else c.oid::regclass::text
    end as lock_target,
    l.mode,
    l.granted
  from pg_locks l
  left join pg_class c on c.oid = l.relation
  left join pg_stat_activity a on a.pid = l.pid
  where (l.locktype = 'advisory'
      and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1)
    or (l.relation in (
      'public.catalog_items_read'::regclass,
      'public.catalog_item_facet_values_read'::regclass,
      'public.catalog_size_facets_read'::regclass,
      'public.catalog_effective_size_membership_read'::regclass
    ) and l.mode in ('ExclusiveLock', 'AccessExclusiveLock'))
), report_rows as (
  select
    l.checked_at_utc,
    l.pid,
    l.usename,
    l.application_name,
    l.state,
    l.wait_event_type,
    l.wait_event,
    l.xact_start,
    l.query_start,
    l.query_sample,
    l.locktype,
    l.lock_target,
    l.mode,
    l.granted,
    s.requested_version,
    s.completed_version,
    s.last_status,
    s.refresh_started_at,
    s.refresh_completed_at
  from lock_rows l
  cross join public.catalog_read_model_refresh_state s
  where s.singleton

  union all

  select
    clock_timestamp(),
    null::integer,
    null::text,
    null::text,
    null::text,
    null::text,
    null::text,
    null::timestamptz,
    null::timestamptz,
    null::text,
    'none'::text,
    'NO_MATCHING_REFRESH_LOCK'::text,
    null::text,
    false,
    s.requested_version,
    s.completed_version,
    s.last_status,
    s.refresh_started_at,
    s.refresh_completed_at
  from public.catalog_read_model_refresh_state s
  where s.singleton
    and not exists (select 1 from lock_rows)
)
select * from report_rows
order by pid nulls last, locktype;

rollback;
