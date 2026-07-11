# Raw sync Storage rollout

The automatic migration creates the private `sync-raw` bucket, sample membership and artifact manifest,
and replaces raw-writing RPC behavior. It intentionally keeps `product_detail_raw` until the archive is verified.

## Rollout

1. Apply `20260711131529_archive_product_sync_raw_payloads.sql`.
2. Deploy the sync and API changes.
3. Run `npm run archive:raw --workspace @catalog/sync` once with production service-role configuration.
4. Run a 50-product metadata canary. Confirm `product_detail_raw` does not grow and the admin debug endpoint reads a sampled payload.
5. Run the verification queries below. Only then create a Supabase migration from the guarded finalization SQL.

```sql
select count(*) as sample_members from public.product_raw_sample_members;

select artifact_kind, upload_status, count(*)
from public.product_sync_artifacts
group by artifact_kind, upload_status
order by artifact_kind, upload_status;

select pg_size_pretty(pg_total_relation_size('public.product_detail_raw')) as legacy_raw_size;
```

## Guarded finalization SQL

```sql
do $$
declare
  v_members integer;
  v_ready integer;
begin
  select count(*) into v_members from public.product_raw_sample_members;
  select count(distinct product_id) into v_ready
  from public.product_sync_artifacts
  where artifact_kind = 'success_sample' and upload_status = 'ready';

  if v_members = 0 or v_ready < v_members then
    raise exception 'Raw archive is incomplete: % of % sample members are ready', v_ready, v_members;
  end if;
end $$;

drop function public.complete_product_detail(uuid, uuid, integer, jsonb, text, text, jsonb);
drop table public.product_detail_raw;
```

After finalization, verify the database size directly with `pg_database_size(current_database())` and run Supabase
security and performance advisors.
