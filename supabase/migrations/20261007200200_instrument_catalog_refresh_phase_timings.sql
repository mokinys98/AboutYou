-- Emit one structured PostgreSQL log line per catalog refresh phase.
-- This migration does not start a refresh, change its order, alter timeouts,
-- change ownership, or change function privileges.
begin;

do $$
declare
  v_owner text;
  v_definition_md5 text;
begin
  select pg_get_userbyid(p.proowner), md5(lower(pg_get_functiondef(p.oid)))
  into v_owner, v_definition_md5
  from pg_proc p
  where p.oid = 'public.process_catalog_items_read_refresh()'::regprocedure;

  if v_owner is distinct from current_user
    or v_definition_md5 is distinct from 'e69f8b62387371f55edc764bab65fdb2'
  then
    raise exception 'Unexpected process_catalog_items_read_refresh() owner or definition; inspect VPS before applying';
  end if;

  select pg_get_userbyid(p.proowner), md5(lower(pg_get_functiondef(p.oid)))
  into v_owner, v_definition_md5
  from pg_proc p
  where p.oid = 'public.rebuild_catalog_items_read_internal()'::regprocedure;

  if v_owner is distinct from current_user
    or v_definition_md5 is distinct from '51c732f7d268e888b129de9d712eb7d7'
  then
    raise exception 'Unexpected rebuild_catalog_items_read_internal() owner or definition; inspect VPS before applying';
  end if;

  select pg_get_userbyid(p.proowner), md5(lower(pg_get_functiondef(p.oid)))
  into v_owner, v_definition_md5
  from pg_proc p
  where p.oid = 'public.invalidate_catalog_facets_cache()'::regprocedure;

  if v_owner is distinct from current_user
    or v_definition_md5 is distinct from '046edc4c1f4e9cbee4af0623a5b6caea'
  then
    raise exception 'Unexpected invalidate_catalog_facets_cache() owner or definition; inspect VPS before applying';
  end if;
end;
$$;

create or replace function public.invalidate_catalog_facets_cache()
returns void
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_phase text := 'effective_size_membership';
  v_phase_started_at timestamptz := clock_timestamp();
  v_phase_duration_ms bigint;
  v_size_facets jsonb;
  v_run_id text := coalesce(
    nullif(current_setting('app.catalog_refresh_run_id', true), ''),
    format('untracked pid=%s started_at=%s', pg_backend_pid(), clock_timestamp() at time zone 'UTC')
  );
  v_error_state text;
begin
  v_phase_started_at := clock_timestamp();
  execute 'refresh materialized view concurrently public.catalog_effective_size_membership_read';
  v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
  raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=success',
    v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms;

  v_phase := 'static_size_facets_cache';
  v_phase_started_at := clock_timestamp();
  with grouped as (
    select
      sf.domain_key,
      max(sf.domain_label) as domain_label,
      sf.value_key,
      max(sf.display_label) as display_label,
      sf.token,
      min(sf.sort_order) as sort_order
    from public.catalog_effective_size_membership_read sf
    group by sf.domain_key, sf.value_key, sf.token
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'value', grouped.token,
    'label', grouped.display_label,
    'domainKey', grouped.domain_key,
    'domainLabel', grouped.domain_label,
    'valueKey', grouped.value_key,
    'sortOrder', grouped.sort_order
  ) order by grouped.domain_key, grouped.sort_order, grouped.display_label), '[]'::jsonb)
  into v_size_facets
  from grouped;

  insert into public.catalog_static_size_facets_cache(singleton, payload)
  values (true, v_size_facets)
  on conflict (singleton) do update
  set payload = excluded.payload,
      updated_at = now();
  v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
  raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=success',
    v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms;

  v_phase := 'facet_cache_delete';
  v_phase_started_at := clock_timestamp();
  delete from public.catalog_facets_cache;
  v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
  raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=success',
    v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms;

  v_phase := 'root_facet_cache_prewarm';
  v_phase_started_at := clock_timestamp();
  perform public.catalog_facets_cached('{}'::jsonb);
  v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
  raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=success',
    v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms;
exception
  when query_canceled then
    get stacked diagnostics v_error_state = returned_sqlstate;
    v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
    raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=failed sqlstate=%',
      v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms, v_error_state;
    raise exception using errcode = '57014',
      message = format('catalog refresh phase %s after %s ms: %s', v_phase, v_phase_duration_ms, SQLERRM);
  when others then
    get stacked diagnostics v_error_state = returned_sqlstate;
    v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
    raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=failed sqlstate=%',
      v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms, v_error_state;
    raise exception using errcode = v_error_state,
      message = format('catalog refresh phase %s after %s ms: %s', v_phase, v_phase_duration_ms, SQLERRM);
end;
$$;

create or replace function public.rebuild_catalog_items_read_internal()
returns void
language plpgsql security definer
set search_path = public, pg_temp
set lock_timeout = '3s' as $$
declare
  v_phase text := 'catalog_items_read';
  v_phase_started_at timestamptz := clock_timestamp();
  v_phase_duration_ms bigint;
  v_run_id text := coalesce(
    nullif(current_setting('app.catalog_refresh_run_id', true), ''),
    format('untracked pid=%s started_at=%s', pg_backend_pid(), clock_timestamp() at time zone 'UTC')
  );
  v_error_state text;
begin
  v_phase_started_at := clock_timestamp();
  execute 'refresh materialized view concurrently public.catalog_items_read';
  v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
  raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=success',
    v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms;

  v_phase := 'catalog_items_read_analyze';
  v_phase_started_at := clock_timestamp();
  execute 'analyze public.catalog_items_read';
  v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
  raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=success',
    v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms;

  v_phase := 'catalog_item_facet_values_read';
  v_phase_started_at := clock_timestamp();
  execute 'refresh materialized view concurrently public.catalog_item_facet_values_read';
  v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
  raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=success',
    v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms;

  v_phase := 'catalog_size_facets_read';
  v_phase_started_at := clock_timestamp();
  execute 'refresh materialized view concurrently public.catalog_size_facets_read';
  v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
  raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=success',
    v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms;

  v_phase := 'catalog_size_facets_read_analyze';
  v_phase_started_at := clock_timestamp();
  execute 'analyze public.catalog_size_facets_read';
  v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
  raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=success',
    v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms;

  v_phase := 'invalidate_catalog_facets_cache';
  v_phase_started_at := clock_timestamp();
  perform public.invalidate_catalog_facets_cache();
exception
  when query_canceled then
    get stacked diagnostics v_error_state = returned_sqlstate;
    v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
    if v_phase <> 'invalidate_catalog_facets_cache' then
      raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=failed sqlstate=%',
        v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms, v_error_state;
    end if;
    raise exception using errcode = '57014',
      message = format('catalog refresh phase %s after %s ms: %s', v_phase, v_phase_duration_ms, SQLERRM);
  when others then
    get stacked diagnostics v_error_state = returned_sqlstate;
    v_phase_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_phase_started_at)) * 1000));
    if v_phase <> 'invalidate_catalog_facets_cache' then
      raise log 'catalog_refresh_phase run_id=% phase=% started_at_utc=% duration_ms=% outcome=failed sqlstate=%',
        v_run_id, v_phase, to_char(v_phase_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), v_phase_duration_ms, v_error_state;
    end if;
    raise exception using errcode = v_error_state,
      message = format('catalog refresh phase %s after %s ms: %s', v_phase, v_phase_duration_ms, SQLERRM);
end;
$$;

create or replace function public.process_catalog_items_read_refresh()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
set lock_timeout = '3s' as $$
declare
  v_target_version bigint;
  v_completed_version bigint;
  v_requested_after bigint;
  v_started_at timestamptz := clock_timestamp();
  v_duration_ms bigint;
  v_error_state text;
  v_error_message text;
  v_run_id text;
begin
  if not pg_try_advisory_xact_lock(hashtext('catalog_items_read_refresh')) then
    return jsonb_build_object('status', 'busy');
  end if;

  select requested_version, completed_version
  into v_target_version, v_completed_version
  from public.catalog_read_model_refresh_state
  where singleton;

  if v_target_version is null or v_completed_version >= v_target_version then
    update public.catalog_read_model_refresh_state
    set last_status = 'clean', last_error = null, updated_at = now()
    where singleton;
    return jsonb_build_object(
      'status', 'clean',
      'requestedVersion', coalesce(v_target_version, 0),
      'completedVersion', coalesce(v_completed_version, 0)
    );
  end if;

  v_run_id := format('version=%s pid=%s started_at=%s', v_target_version, pg_backend_pid(),
    to_char(v_started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
  perform set_config('app.catalog_refresh_run_id', v_run_id, true);

  begin
    perform public.rebuild_catalog_items_read_internal();
  exception
    when query_canceled then
      get stacked diagnostics v_error_state = returned_sqlstate, v_error_message = message_text;
      v_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_started_at)) * 1000));
      update public.catalog_read_model_refresh_state
      set refresh_started_at = v_started_at,
          refresh_completed_at = clock_timestamp(),
          last_status = 'failed',
          last_duration_ms = v_duration_ms,
          last_error = left(v_error_state || ': ' || v_error_message, 1000),
          updated_at = now()
      where singleton;
      raise log 'catalog_refresh_run run_id=% outcome=failed duration_ms=% sqlstate=%', v_run_id, v_duration_ms, v_error_state;
      return jsonb_build_object('status', 'failed', 'error', v_error_state, 'durationMs', v_duration_ms);
    when others then
      get stacked diagnostics v_error_state = returned_sqlstate, v_error_message = message_text;
      v_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_started_at)) * 1000));
      update public.catalog_read_model_refresh_state
      set refresh_started_at = v_started_at,
          refresh_completed_at = clock_timestamp(),
          last_status = 'failed',
          last_duration_ms = v_duration_ms,
          last_error = left(v_error_state || ': ' || v_error_message, 1000),
          updated_at = now()
      where singleton;
      raise log 'catalog_refresh_run run_id=% outcome=failed duration_ms=% sqlstate=%', v_run_id, v_duration_ms, v_error_state;
      return jsonb_build_object('status', 'failed', 'error', v_error_state, 'durationMs', v_duration_ms);
  end;

  v_duration_ms := greatest(0, round(extract(epoch from (clock_timestamp() - v_started_at)) * 1000));
  update public.catalog_read_model_refresh_state
  set completed_version = greatest(completed_version, v_target_version),
      refresh_started_at = v_started_at,
      refresh_completed_at = clock_timestamp(),
      last_status = 'refreshed',
      last_duration_ms = v_duration_ms,
      last_error = null,
      updated_at = now()
  where singleton
  returning requested_version into v_requested_after;

  raise log 'catalog_refresh_run run_id=% outcome=success duration_ms=% target_version=% requested_after=%',
    v_run_id, v_duration_ms, v_target_version, v_requested_after;

  return jsonb_build_object(
    'status', 'refreshed',
    'requestedVersion', v_requested_after,
    'completedVersion', v_target_version,
    'dirty', v_requested_after > v_target_version,
    'durationMs', v_duration_ms
  );
end;
$$;

commit;
