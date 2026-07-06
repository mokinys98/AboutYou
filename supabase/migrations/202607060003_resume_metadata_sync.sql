-- Metadata sync processes only unchecked products. Products whose color was
-- already obtained by catalog discovery do not need a detail-page request.
update public.products
set metadata_updated_at = updated_at
where metadata_updated_at is null and color_original is not null;

create index if not exists products_metadata_pending_idx
  on public.products (source_id, id)
  where active and metadata_updated_at is null;
