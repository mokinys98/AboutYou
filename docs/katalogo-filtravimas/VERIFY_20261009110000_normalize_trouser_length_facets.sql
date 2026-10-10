-- Read-only validation for migration 20261009110000.
-- Expected: rows marked true; trailing known descriptions are removed,
-- meaningful ranges stay ranges, and ambiguous trouser values stay distinct.
select
  public.catalog_strip_known_size_description(
    'L Normalaus dydžio / Normalaus dydžio'
  ) = 'l' as strips_apparel_description,
  public.catalog_strip_known_size_description(
    '42 Normalaus dydžio / Normalaus dydžio'
  ) = '42' as preserves_numeric_eu_size,
  public.catalog_strip_known_size_description(
    'Vienas dydis x vieno dydžio / vieno dydžio'
  ) = 'Vienas dydis' as groups_one_size_aliases,
  public.catalog_strip_known_size_description(
    'Einheitsgröße'
  ) = 'Vienas dydis' as groups_german_one_size_alias,
  public.catalog_strip_known_size_description(
    '40,5-41 įprastas dydis'
  ) = '40,5-41' as preserves_shoe_range,
  public.catalog_effective_size_value_key(
    'shoes', public.catalog_strip_known_size_description('40,5-41 įprastas dydis')
  ) = '40.5-41' as canonical_shoe_range_key,
  public.catalog_canonical_size_token(
    'shoes:40,5-41 įprastas dydis'
  ) = 'shoes:40.5-41' as canonical_shoe_range_token,
  public.catalog_normalize_trouser_size_value(
    '29 x 30 / 30'
  ) = 'w29-l30' as keeps_explicit_trouser_pair,
  public.catalog_normalize_trouser_size_value(
    '29-30'
  ) is null as leaves_ambiguous_numeric_range_unmapped,
  public.catalog_normalize_trouser_size_value(
    'ilgis-30 / ilgis-30'
  ) = 'l30' as keeps_inseam_only_separate,
  public.catalog_canonical_size_tokens(
    'trousers:29-30'
  ) = array['trousers:29-30']::text[] as keeps_legacy_range_unambiguous,
  public.catalog_canonical_size_tokens(
    'trousers:29 x 30'
  ) = array['trousers:w29-l30']::text[] as canonicalizes_explicit_pair,
  public.catalog_canonical_size_tokens(
    'gloves:S-M'
  ) = array['gloves:s', 'gloves:m']::text[] as expands_apparel_range,
  public.catalog_canonical_size_tokens(
    'shoes:S-M'
  ) = array['shoes:s-m']::text[] as preserves_nonapparel_range;

-- Current effective output grouped by every inferred size domain.
select domain_key, domain_label, count(distinct token) as effective_size_values,
  count(distinct product_id) as products
from public.catalog_size_facets_read_effective
group by domain_key, domain_label
order by domain_key;

-- Known-description examples should no longer remain as visible facet labels.
select domain_key, token, display_label
from public.catalog_size_facets_read_effective
where display_label ~* '(normalaus|normalus|įprastas|įprasto|ilgis|labai ilgas|trumpas|regular length)'
order by domain_key, sort_order, display_label
limit 50;
