-- Run in Supabase SQL Editor after 20261004130000_normalize_effective_catalog_sizes.sql.
-- Expected: decimal_key = 42.5, one_size_key = one-size,
-- waist_length_order = 32034, next_length_order = 32036;
-- both counts are 0. This checks the materialized result after its refresh.
begin read only;

select
  public.catalog_effective_size_value_key('42,5') as decimal_key,
  public.catalog_effective_size_value_key('Vienas dydis') as one_size_key,
  public.catalog_effective_size_sort_order('w32-l34') as waist_length_order,
  public.catalog_effective_size_sort_order('w32-l36') as next_length_order;

select
  count(*) filter (where value_key ~ '[0-9],[0-9]') as decimal_comma_tokens,
  count(*) filter (where value_key in ('onesize', '1size', 'ns', 'vienas-dydis')) as unnormalized_one_size_tokens
from public.catalog_effective_size_membership_read;

rollback;
