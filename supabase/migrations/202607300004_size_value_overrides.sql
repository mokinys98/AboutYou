-- Add persistent per-size overrides used by the Debug UI.
-- This migration intentionally contains schema changes only.

alter table public.catalog_size_classification_overrides
  add column if not exists size_value_overrides jsonb not null default '{}'::jsonb;

alter table public.catalog_size_classification_overrides
  drop constraint if exists catalog_size_classification_overrides_size_value_overrides_check;

alter table public.catalog_size_classification_overrides
  add constraint catalog_size_classification_overrides_size_value_overrides_check
  check (jsonb_typeof(size_value_overrides) = 'object');
