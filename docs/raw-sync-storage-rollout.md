# Raw sync Storage rollout

The automatic migration creates the private `sync-raw` bucket, sample membership and artifact manifest,
and replaces raw-writing RPC behavior. It intentionally keeps `product_detail_raw` until the archive is verified.

## Rollout

1. Apply `20260711131529_archive_product_sync_raw_payloads.sql`.
2. Publish the new code, but do not start a full sync yet:
   - commit and push these changes to `main`, because the GitHub Action always checks out the selected repository branch;
   - deploy the API Worker with `npm run deploy --workspace @catalog/api`;
   - there is no separate long-running sync service to deploy: `Sync product metadata` downloads the current branch code every time it starts.
3. Run `npm run archive:raw --workspace @catalog/sync` exactly once with production service-role configuration. This exports and verifies the selected existing payloads; it does not crawl ABOUT YOU again.
4. Run the metadata canary exactly once:
   - open GitHub → **Actions** → **Sync product metadata** → **Run workflow**;
   - select the branch containing these changes (`main` after step 2);
   - set **Maximum products to process** to `50` and start the workflow;
   - this is only a smoke test of at most 50 products. Do not repeat it until all products are processed;
   - if it succeeds, confirm `product_detail_raw` size/row count did not increase and open an admin debug view for a sampled product;
   - if it fails, inspect that single run and fix the error before retrying.
5. Run the verification queries below. Only then create a Supabase migration from the guarded finalization SQL. After finalization, the normal hourly metadata schedule can continue processing the catalog in batches; the canary itself is not intended to cover the full catalog.

### Canary verification SQL

Run this query immediately before the 50-product canary and save the result. Run the same query again after the
GitHub Action finishes. `row_count`, `total_bytes`, `payload_bytes`, and `latest_raw_write` must remain unchanged.

```sql
select
  count(*) as row_count,
  pg_total_relation_size('public.product_detail_raw') as total_bytes,
  pg_size_pretty(pg_total_relation_size('public.product_detail_raw')) as total_size,
  coalesce(sum(pg_column_size(payload)), 0) as payload_bytes,
  pg_size_pretty(coalesce(sum(pg_column_size(payload)), 0)) as payload_size,
  max(fetched_at) as latest_raw_write
from public.product_detail_raw;
```

After the canary, use this query to find sampled products whose raw payload is ready in Storage:

```sql
select
  member.sample_rank,
  product.id as product_id,
  product.external_id,
  product.name,
  product.product_url,
  artifact.storage_path,
  artifact.parser_version,
  artifact.created_at
from public.product_raw_sample_members member
join public.products product on product.id = member.product_id
join public.product_sync_artifacts artifact
  on artifact.product_id = member.product_id
  and artifact.artifact_kind = 'success_sample'
  and artifact.upload_status = 'ready'
where product.active
order by artifact.created_at desc
limit 10;
```

Copy one returned `product_id`, sign in as an admin, enable **Produkto debug režimas** on the profile page, and open
`/products/{product_id}/debug`. The UI does not print the `rawAvailable` field literally. A successful Storage read is
shown by the **Pilnas sanitizuotas API payload** section containing JSON instead of the “Raw payload šiam produktui
dar nesurinktas” message. To inspect `rawAvailable: true` itself, open browser DevTools → Network and inspect the
`/v1/products/{product_id}/debug` response. Remember that a Cloudflare Pages rebuild updates only the web app; the
separate API Worker must also be deployed with `npm run deploy --workspace @catalog/api`. If the second query returns no rows,
do not finalize the migration: inspect the canary logs for `raw_archive_failed` or Storage upload errors.

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
