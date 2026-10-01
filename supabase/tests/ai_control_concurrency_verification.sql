-- Read-only verification in the VPS Supabase SQL Editor after applying
-- 20261001090000_ai_control_concurrency.sql.
select
  to_regclass('public.ai_control_one_in_flight_idx') is null as old_gate_removed,
  to_regclass('public.ai_control_product_in_flight_idx') is not null as product_guard_present,
  to_regclass('public.ai_control_unresolved_status_idx') is not null as unresolved_index_present,
  position('pg_advisory_xact_lock' in pg_get_functiondef(
    'public.reserve_ai_control_request(uuid,uuid,text,integer,integer)'::regprocedure
  )) > 0 as global_reservation_lock_present,
  position('>= 5' in pg_get_functiondef(
    'public.reserve_ai_control_request(uuid,uuid,text,integer,integer)'::regprocedure
  )) > 0 as five_request_limit_present,
  has_function_privilege('service_role',
    'public.reserve_ai_control_request(uuid,uuid,text,integer,integer)', 'execute') as server_can_reserve,
  not has_function_privilege('authenticated',
    'public.reserve_ai_control_request(uuid,uuid,text,integer,integer)', 'execute') as client_cannot_reserve,
  (select count(*) from public.ai_control_requests where status = 'reserved') as active_requests,
  (select count(*) from public.ai_control_requests where status = 'uncertain') as uncertain_requests;
