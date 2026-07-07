-- Keep bounded metadata-sync failure evidence outside the primary product tables.
create table public.product_sync_diagnostics (
  id bigint generated always as identity primary key,
  product_id uuid not null references public.products(id) on delete cascade,
  checked_at timestamptz not null default now(),
  error_code text not null check (trim(error_code) <> ''),
  http_status integer check (http_status between 100 and 599),
  content_type text,
  response_size bigint check (response_size is null or response_size >= 0),
  final_url text,
  html_storage_path text,
  parser_version integer not null check (parser_version > 0)
);

create index product_sync_diagnostics_checked_at_idx
  on public.product_sync_diagnostics(checked_at);
create index product_sync_diagnostics_product_idx
  on public.product_sync_diagnostics(product_id, checked_at desc);

alter table public.product_sync_diagnostics enable row level security;
revoke all on table public.product_sync_diagnostics from public, anon, authenticated;
grant all on table public.product_sync_diagnostics to service_role;
grant usage, select on sequence public.product_sync_diagnostics_id_seq to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sync-debug', 'sync-debug', false, 5242880, array['application/gzip'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
