-- Read-only check for the trouser length label patterns reported on 2026-10-09.
select
  input,
  public.catalog_normalize_trouser_size_value(input) as normalized_key,
  public.catalog_canonical_size_tokens('trousers:' || input) as filter_tokens
from (values
  ('29-30-įprastas-ilgis-/-įprastas-ilgis'),
  ('31-32-trumpas-/-trumpas'),
  ('34-labai-ilgas-/-labai-ilgas'),
  ('ilgis-30-/-ilgis-30'),
  ('33 x 34 / 34'),
  ('30 x 32 / 32')
) as samples(input);

-- Expected normalized keys: w29-l30, w31-l32, 34, 30, w33-l34, w30-l32.
-- Each filter_tokens array should contain only its canonical trousers token.
