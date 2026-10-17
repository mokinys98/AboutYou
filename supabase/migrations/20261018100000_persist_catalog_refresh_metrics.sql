-- Persist catalog refresh run outcomes and phase timings, including completed
-- phases whose SQL writes roll back with a later PL/pgSQL exception.
begin;

do $$
declare
  v_owner text;
  v_definition_md5 text;
begin
  if current_user <> 'postgres' then
    raise exception 'Expected SQL Editor role postgres, got %', current_user;
  end if;
  select pg_get_userbyid(p.proowner), md5(lower(pg_get_functiondef(p.oid)))
    into v_owner, v_definition_md5
  from pg_proc p where p.oid = 'public.process_catalog_items_read_refresh()'::regprocedure;
  if v_owner is distinct from 'postgres' or v_definition_md5 is distinct from 'c516319f2067ec2a1a8a05341251168a' then
    raise exception 'Unexpected process_catalog_items_read_refresh() owner or definition; inspect VPS before applying';
  end if;

  select pg_get_userbyid(p.proowner), md5(lower(pg_get_functiondef(p.oid)))
    into v_owner, v_definition_md5
  from pg_proc p where p.oid = 'public.rebuild_catalog_items_read_internal()'::regprocedure;
  if v_owner is distinct from 'postgres' or v_definition_md5 is distinct from 'f1d0ebf497c8d9c0fefd00cb6b49cbaf' then
    raise exception 'Unexpected rebuild_catalog_items_read_internal() owner or definition; inspect VPS before applying';
  end if;

  select pg_get_userbyid(p.proowner), md5(lower(pg_get_functiondef(p.oid)))
    into v_owner, v_definition_md5
  from pg_proc p where p.oid = 'public.invalidate_catalog_facets_cache()'::regprocedure;
  if v_owner is distinct from 'postgres' or v_definition_md5 is distinct from '6b4bdd0e54aa873d27ee490502faabb0' then
    raise exception 'Unexpected invalidate_catalog_facets_cache() owner or definition; inspect VPS before applying';
  end if;

  if not (select count(*) = 1 and coalesce(bool_and(not active), false)
      from cron.job where jobname = 'catalog-read-model-refresh') then
    raise exception 'Expected exactly one paused catalog refresh cron job';
  end if;
  if exists (
    select 1 from cron.job_run_details r
    join cron.job j on j.jobid = r.jobid
    where j.jobname = 'catalog-read-model-refresh'
      and r.status = 'running' and r.end_time is null
  ) or exists (
    select 1 from pg_locks l
    where l.locktype = 'advisory' and l.classid = 0::oid
      and l.objid = hashtext('catalog_items_read_refresh')::oid
      and l.objsubid = 1 and l.granted
  ) then
    raise exception 'A catalog refresh may be active; inspect before applying';
  end if;
end;
$$;

create sequence public.catalog_refresh_metrics_run_id_seq;
create table public.catalog_refresh_runs (
  run_id bigint primary key,
  started_at timestamptz not null,
  completed_at timestamptz not null,
  duration_ms bigint not null check (duration_ms >= 0),
  outcome text not null check (outcome in ('busy', 'clean', 'refreshed', 'failed')),
  target_version bigint,
  requested_after bigint,
  failure_phase text,
  error_sqlstate text,
  error_message text,
  check ((outcome = 'failed') = (failure_phase is not null))
);
create index catalog_refresh_runs_started_at_idx on public.catalog_refresh_runs (started_at desc);

create table public.catalog_refresh_phases (
  phase_id bigint generated always as identity primary key,
  run_id bigint not null references public.catalog_refresh_runs(run_id)
    deferrable initially deferred,
  phase text not null,
  started_at timestamptz not null,
  duration_ms bigint not null check (duration_ms >= 0),
  outcome text not null check (outcome in ('success', 'failed')),
  error_sqlstate text,
  check ((outcome = 'failed') = (error_sqlstate is not null))
);
create index catalog_refresh_phases_run_id_idx on public.catalog_refresh_phases (run_id, phase_id);

revoke all on sequence public.catalog_refresh_metrics_run_id_seq from public, anon, authenticated, service_role;
revoke all on table public.catalog_refresh_runs, public.catalog_refresh_phases from public, anon, authenticated, service_role;
alter table public.catalog_refresh_runs enable row level security;
alter table public.catalog_refresh_phases enable row level security;
-- The established VPS diagnostics login needs SELECT for post-application
-- verification. No write privilege is granted to it.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'codex_reader') then
    grant select on public.catalog_refresh_runs, public.catalog_refresh_phases to codex_reader;
  end if;
end;
$$;

create or replace function public.record_catalog_refresh_phase(
  p_run_id bigint, p_phase text, p_started_at timestamptz, p_duration_ms bigint,
  p_outcome text default 'success', p_error_sqlstate text default null
) returns void
language sql security definer
set search_path = public, pg_temp as $$
  insert into public.catalog_refresh_phases(run_id, phase, started_at, duration_ms, outcome, error_sqlstate)
  values (p_run_id, p_phase, p_started_at, greatest(0, p_duration_ms), p_outcome, p_error_sqlstate)
$$;
revoke all on function public.record_catalog_refresh_phase(bigint, text, timestamptz, bigint, text, text) from public, anon, authenticated, service_role;

create or replace function public.invalidate_catalog_facets_cache()
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_phase text := 'effective_size_membership';
  v_phase_started_at timestamptz := clock_timestamp();
  v_duration_ms bigint;
  v_size_facets jsonb;
  v_run_id bigint := nullif(current_setting('app.catalog_refresh_metrics_run_id', true), '')::bigint;
  v_phases jsonb := '[]'::jsonb;
  v_error_state text;
  v_error_message text;
  v_failed_duration bigint;
begin
  v_phase_started_at := clock_timestamp();
  execute 'refresh materialized view concurrently public.catalog_effective_size_membership_read';
  v_duration_ms := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  if v_run_id is not null then perform public.record_catalog_refresh_phase(v_run_id, v_phase, v_phase_started_at, v_duration_ms); end if;
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_duration_ms, 'outcome', 'success', 'error_sqlstate', null));

  v_phase := 'static_size_facets_cache'; v_phase_started_at := clock_timestamp();
  with grouped as (
    select sf.domain_key, max(sf.domain_label) as domain_label, sf.value_key,
      max(sf.display_label) as display_label, sf.token, min(sf.sort_order) as sort_order
    from public.catalog_effective_size_membership_read sf group by sf.domain_key, sf.value_key, sf.token
  )
  select coalesce(jsonb_agg(jsonb_build_object('value', grouped.token, 'label', grouped.display_label,
    'domainKey', grouped.domain_key, 'domainLabel', grouped.domain_label, 'valueKey', grouped.value_key,
    'sortOrder', grouped.sort_order) order by grouped.domain_key, grouped.sort_order, grouped.display_label), '[]'::jsonb)
  into v_size_facets from grouped;
  insert into public.catalog_static_size_facets_cache(singleton, payload) values (true, v_size_facets)
  on conflict (singleton) do update set payload = excluded.payload, updated_at = now();
  v_duration_ms := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  if v_run_id is not null then perform public.record_catalog_refresh_phase(v_run_id, v_phase, v_phase_started_at, v_duration_ms); end if;
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_duration_ms, 'outcome', 'success', 'error_sqlstate', null));

  v_phase := 'facet_cache_delete'; v_phase_started_at := clock_timestamp();
  delete from public.catalog_facets_cache;
  v_duration_ms := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  if v_run_id is not null then perform public.record_catalog_refresh_phase(v_run_id, v_phase, v_phase_started_at, v_duration_ms); end if;
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_duration_ms, 'outcome', 'success', 'error_sqlstate', null));

  v_phase := 'root_facet_cache_prewarm'; v_phase_started_at := clock_timestamp();
  perform public.catalog_facets_cached('{}'::jsonb);
  v_duration_ms := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  if v_run_id is not null then perform public.record_catalog_refresh_phase(v_run_id, v_phase, v_phase_started_at, v_duration_ms); end if;
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_duration_ms, 'outcome', 'success', 'error_sqlstate', null));
exception when query_canceled then
  get stacked diagnostics v_error_state = returned_sqlstate, v_error_message = message_text;
  v_failed_duration := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_failed_duration, 'outcome', 'failed', 'error_sqlstate', v_error_state));
  raise exception using errcode = '57014',
    message = format('catalog refresh phase %s after %s ms: %s', v_phase, v_failed_duration, v_error_message),
    detail = jsonb_build_object('version', 1, 'phases', v_phases)::text;
when others then
  get stacked diagnostics v_error_state = returned_sqlstate, v_error_message = message_text;
  v_failed_duration := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_failed_duration, 'outcome', 'failed', 'error_sqlstate', v_error_state));
  raise exception using errcode = v_error_state,
    message = format('catalog refresh phase %s after %s ms: %s', v_phase, v_failed_duration, v_error_message),
    detail = jsonb_build_object('version', 1, 'phases', v_phases)::text;
end;
$$;

create or replace function public.rebuild_catalog_items_read_internal()
returns void language plpgsql security definer
set search_path = public, pg_temp set lock_timeout = '3s' as $$
declare
  v_phase text := 'catalog_items_read';
  v_phase_started_at timestamptz := clock_timestamp();
  v_duration_ms bigint;
  v_run_id bigint := nullif(current_setting('app.catalog_refresh_metrics_run_id', true), '')::bigint;
  v_phases jsonb := '[]'::jsonb;
  v_error_state text;
  v_error_message text;
  v_error_detail text;
  v_nested_phases jsonb;
  v_failed_duration bigint;
begin
  v_phase_started_at := clock_timestamp(); execute 'refresh materialized view concurrently public.catalog_items_read';
  v_duration_ms := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  if v_run_id is not null then perform public.record_catalog_refresh_phase(v_run_id, v_phase, v_phase_started_at, v_duration_ms); end if;
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_duration_ms, 'outcome', 'success', 'error_sqlstate', null));
  v_phase := 'catalog_items_read_analyze'; v_phase_started_at := clock_timestamp(); execute 'analyze public.catalog_items_read';
  v_duration_ms := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  if v_run_id is not null then perform public.record_catalog_refresh_phase(v_run_id, v_phase, v_phase_started_at, v_duration_ms); end if;
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_duration_ms, 'outcome', 'success', 'error_sqlstate', null));
  v_phase := 'catalog_item_facet_values_read'; v_phase_started_at := clock_timestamp(); execute 'refresh materialized view concurrently public.catalog_item_facet_values_read';
  v_duration_ms := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  if v_run_id is not null then perform public.record_catalog_refresh_phase(v_run_id, v_phase, v_phase_started_at, v_duration_ms); end if;
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_duration_ms, 'outcome', 'success', 'error_sqlstate', null));
  v_phase := 'catalog_size_facets_read'; v_phase_started_at := clock_timestamp(); execute 'refresh materialized view concurrently public.catalog_size_facets_read';
  v_duration_ms := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  if v_run_id is not null then perform public.record_catalog_refresh_phase(v_run_id, v_phase, v_phase_started_at, v_duration_ms); end if;
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_duration_ms, 'outcome', 'success', 'error_sqlstate', null));
  v_phase := 'catalog_size_facets_read_analyze'; v_phase_started_at := clock_timestamp(); execute 'analyze public.catalog_size_facets_read';
  v_duration_ms := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  if v_run_id is not null then perform public.record_catalog_refresh_phase(v_run_id, v_phase, v_phase_started_at, v_duration_ms); end if;
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_duration_ms, 'outcome', 'success', 'error_sqlstate', null));
  v_phase := 'invalidate_catalog_facets_cache'; v_phase_started_at := clock_timestamp(); perform public.invalidate_catalog_facets_cache();
exception when query_canceled then
  get stacked diagnostics v_error_state = returned_sqlstate, v_error_message = message_text, v_error_detail = pg_exception_detail;
  if v_phase = 'invalidate_catalog_facets_cache' then
    begin
      if v_error_detail is not null and jsonb_typeof(v_error_detail::jsonb) = 'object'
         and (v_error_detail::jsonb->>'version') = '1'
         and jsonb_typeof(v_error_detail::jsonb->'phases') = 'array' then
        v_nested_phases := v_error_detail::jsonb->'phases';
      else
        v_nested_phases := null;
      end if;
    exception when others then v_nested_phases := null;
    end;
    if v_nested_phases is not null then
      v_phases := v_phases || v_nested_phases;
      raise exception using errcode = '57014', message = v_error_message,
        detail = jsonb_build_object('version', 1, 'phases', v_phases)::text;
    end if;
  end if;
  v_failed_duration := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_failed_duration, 'outcome', 'failed', 'error_sqlstate', v_error_state));
  raise exception using errcode = '57014',
    message = format('catalog refresh phase %s after %s ms: %s', v_phase, v_failed_duration, v_error_message),
    detail = jsonb_build_object('version', 1, 'phases', v_phases)::text;
when others then
  get stacked diagnostics v_error_state = returned_sqlstate, v_error_message = message_text, v_error_detail = pg_exception_detail;
  if v_phase = 'invalidate_catalog_facets_cache' then
    begin
      if v_error_detail is not null and jsonb_typeof(v_error_detail::jsonb) = 'object'
         and (v_error_detail::jsonb->>'version') = '1'
         and jsonb_typeof(v_error_detail::jsonb->'phases') = 'array' then
        v_nested_phases := v_error_detail::jsonb->'phases';
      else
        v_nested_phases := null;
      end if;
    exception when others then v_nested_phases := null;
    end;
    if v_nested_phases is not null then
      v_phases := v_phases || v_nested_phases;
      raise exception using errcode = v_error_state, message = v_error_message,
        detail = jsonb_build_object('version', 1, 'phases', v_phases)::text;
    end if;
  end if;
  v_failed_duration := greatest(0, round(extract(epoch from clock_timestamp() - v_phase_started_at) * 1000));
  v_phases := v_phases || jsonb_build_array(jsonb_build_object('phase', v_phase, 'started_at', v_phase_started_at, 'duration_ms', v_failed_duration, 'outcome', 'failed', 'error_sqlstate', v_error_state));
  raise exception using errcode = v_error_state,
    message = format('catalog refresh phase %s after %s ms: %s', v_phase, v_failed_duration, v_error_message),
    detail = jsonb_build_object('version', 1, 'phases', v_phases)::text;
end;
$$;

create or replace function public.process_catalog_items_read_refresh()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp set lock_timeout = '3s' as $$
declare
  v_target_version bigint; v_completed_version bigint; v_requested_after bigint;
  v_started_at timestamptz := clock_timestamp(); v_finished_at timestamptz; v_duration_ms bigint;
  v_error_state text; v_error_message text; v_error_detail text; v_run_id bigint := nextval('public.catalog_refresh_metrics_run_id_seq');
  v_failure_phase text; v_failure_duration bigint;
  v_phase_rows jsonb := '[]'::jsonb; v_phase_item jsonb; v_phase_name text;
  v_phase_started_at timestamptz; v_phase_duration bigint; v_phase_outcome text; v_phase_error text;
  v_phase_payload jsonb; v_bad_payload boolean := false; v_phase_count integer := 0; v_failed_count integer := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('catalog_items_read_refresh')) then
    v_finished_at := clock_timestamp();
    insert into public.catalog_refresh_runs(run_id, started_at, completed_at, duration_ms, outcome)
    values (v_run_id, v_started_at, v_finished_at, greatest(0, round(extract(epoch from v_finished_at-v_started_at)*1000)), 'busy');
    return jsonb_build_object('status', 'busy');
  end if;
  select requested_version, completed_version into v_target_version, v_completed_version
  from public.catalog_read_model_refresh_state where singleton;
  if v_target_version is null or v_completed_version >= v_target_version then
    update public.catalog_read_model_refresh_state set last_status='clean', last_error=null, updated_at=now() where singleton;
    v_finished_at := clock_timestamp();
    insert into public.catalog_refresh_runs(run_id, started_at, completed_at, duration_ms, outcome, target_version)
    values (v_run_id, v_started_at, v_finished_at, greatest(0, round(extract(epoch from v_finished_at-v_started_at)*1000)), 'clean', coalesce(v_target_version,0));
    return jsonb_build_object('status','clean','requestedVersion',coalesce(v_target_version,0),'completedVersion',coalesce(v_completed_version,0));
  end if;
  perform set_config('app.catalog_refresh_run_id', format('version=%s pid=%s started_at=%s', v_target_version, pg_backend_pid(), to_char(v_started_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')), true);
  perform set_config('app.catalog_refresh_metrics_run_id', v_run_id::text, true);
  begin
    perform public.rebuild_catalog_items_read_internal();
  exception when query_canceled then
    get stacked diagnostics v_error_state = returned_sqlstate, v_error_message = message_text, v_error_detail = pg_exception_detail;
  when others then
    get stacked diagnostics v_error_state = returned_sqlstate, v_error_message = message_text, v_error_detail = pg_exception_detail;
  end;
  if v_error_state is not null then
    v_duration_ms := greatest(0, round(extract(epoch from clock_timestamp()-v_started_at)*1000));
    v_finished_at := clock_timestamp();
    v_failure_phase := (regexp_match(v_error_message, '^catalog refresh phase ([a-z0-9_]+) after ([0-9]+) ms:'))[1];
    v_failure_duration := coalesce(((regexp_match(v_error_message, '^catalog refresh phase ([a-z0-9_]+) after ([0-9]+) ms:'))[2])::bigint, v_duration_ms);

    -- Exception DETAIL crosses the helper subtransaction rollback boundary.
    -- Accept only our versioned payload and validate each row before casting;
    -- malformed or unrelated DETAIL falls back to one terminal failed phase.
    begin
      if v_error_detail is null then raise exception 'missing phase detail'; end if;
      v_phase_payload := v_error_detail::jsonb;
      if jsonb_typeof(v_phase_payload) <> 'object'
         or v_phase_payload->>'version' <> '1'
         or jsonb_typeof(v_phase_payload->'phases') <> 'array' then
        raise exception 'unexpected phase detail payload';
      end if;
      for v_phase_item in select value from jsonb_array_elements(v_phase_payload->'phases') loop
        begin
          if jsonb_typeof(v_phase_item) <> 'object' then raise exception 'invalid phase row'; end if;
          v_phase_name := v_phase_item->>'phase';
          v_phase_outcome := v_phase_item->>'outcome';
          v_phase_error := v_phase_item->>'error_sqlstate';
          if v_phase_name is null or v_phase_name not in ('catalog_items_read','catalog_items_read_analyze',
              'catalog_item_facet_values_read','catalog_size_facets_read',
              'catalog_size_facets_read_analyze','effective_size_membership',
              'static_size_facets_cache','facet_cache_delete','root_facet_cache_prewarm')
             or v_phase_outcome is null or v_phase_outcome not in ('success','failed')
             or v_phase_item->>'duration_ms' is null or (v_phase_item->>'duration_ms') !~ '^[0-9]+$'
             or v_phase_item->>'started_at' is null
             or (v_phase_outcome = 'success' and v_phase_error is not null)
             or (v_phase_outcome = 'failed' and (v_phase_error is null or v_phase_error !~ '^[0-9A-Z]{5}$')) then
            raise exception 'invalid phase row fields';
          end if;
          v_phase_started_at := (v_phase_item->>'started_at')::timestamptz;
          v_phase_duration := (v_phase_item->>'duration_ms')::bigint;
          v_phase_rows := v_phase_rows || jsonb_build_array(jsonb_build_object(
            'phase',v_phase_name,'started_at',v_phase_started_at,'duration_ms',v_phase_duration,
            'outcome',v_phase_outcome,'error_sqlstate',v_phase_error));
          v_phase_count := v_phase_count + 1;
          if v_phase_outcome = 'failed' then v_failed_count := v_failed_count + 1; end if;
        exception when others then
          v_bad_payload := true;
          exit;
        end;
      end loop;
      if v_bad_payload or v_phase_count = 0 or v_failed_count <> 1
         or exists (select 1 from jsonb_to_recordset(v_phase_rows) as phases(phase text)
                    group by phase having count(*) > 1) then
        raise exception 'invalid or empty phase detail';
      end if;
    exception when others then
      v_phase_rows := '[]'::jsonb;
      v_phase_count := 0;
      v_failed_count := 0;
    end;
    if v_phase_count = 0 then
      v_failure_phase := coalesce(v_failure_phase, 'unknown');
      v_failure_duration := coalesce(v_failure_duration, v_duration_ms);
      v_phase_rows := jsonb_build_array(jsonb_build_object(
        'phase',v_failure_phase,
        'started_at',greatest(v_started_at,v_finished_at-(v_failure_duration*interval '1 millisecond')),
        'duration_ms',v_failure_duration,'outcome','failed','error_sqlstate',v_error_state));
    end if;
    if v_failure_phase is null then
      select phase into v_failure_phase from jsonb_to_recordset(v_phase_rows)
        as phases(phase text, outcome text) where outcome='failed' limit 1;
    end if;
    update public.catalog_read_model_refresh_state set refresh_started_at=v_started_at, refresh_completed_at=v_finished_at,
      last_status='failed', last_duration_ms=v_duration_ms, last_error=left(v_error_state||': '||v_error_message,1000), updated_at=now() where singleton;
    insert into public.catalog_refresh_runs(run_id,started_at,completed_at,duration_ms,outcome,target_version,failure_phase,error_sqlstate,error_message)
    values (v_run_id,v_started_at,v_finished_at,v_duration_ms,'failed',v_target_version,coalesce(v_failure_phase,'unknown'),v_error_state,left(v_error_message,1000));
    insert into public.catalog_refresh_phases(run_id,phase,started_at,duration_ms,outcome,error_sqlstate)
    select v_run_id, phase, started_at, duration_ms, outcome, error_sqlstate
    from jsonb_to_recordset(v_phase_rows) as phases(
      phase text, started_at timestamptz, duration_ms bigint, outcome text, error_sqlstate text);
    perform set_config('app.catalog_refresh_metrics_run_id', '', true);
    perform set_config('app.catalog_refresh_run_id', '', true);
    return jsonb_build_object('status','failed','error',v_error_state,'durationMs',v_duration_ms);
  end if;
  v_finished_at := clock_timestamp(); v_duration_ms := greatest(0, round(extract(epoch from v_finished_at-v_started_at)*1000));
  update public.catalog_read_model_refresh_state set completed_version=greatest(completed_version,v_target_version),
    refresh_started_at=v_started_at, refresh_completed_at=v_finished_at, last_status='refreshed',last_duration_ms=v_duration_ms,last_error=null,updated_at=now()
  where singleton returning requested_version into v_requested_after;
  insert into public.catalog_refresh_runs(run_id,started_at,completed_at,duration_ms,outcome,target_version,requested_after)
  values(v_run_id,v_started_at,v_finished_at,v_duration_ms,'refreshed',v_target_version,v_requested_after);
  perform set_config('app.catalog_refresh_metrics_run_id', '', true);
  perform set_config('app.catalog_refresh_run_id', '', true);
  return jsonb_build_object('status','refreshed','requestedVersion',v_requested_after,'completedVersion',v_target_version,'dirty',v_requested_after>v_target_version,'durationMs',v_duration_ms);
end;
$$;

commit;
