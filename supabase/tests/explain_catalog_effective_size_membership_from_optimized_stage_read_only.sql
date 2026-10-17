-- Read-only source-plan diagnostic for the populated optimized stage.
-- The effective-size view definition was read from the current VPS definition,
-- with its size-facet input redirected to the stage relation. This measures
-- membership grouping cost; it does not refresh any materialized view.
-- Run in SQL Editor while cron remains paused. If the 30s timeout occurs,
-- record the error and do not retry with a longer timeout.
begin read only;
set local statement_timeout = '30s';
set local lock_timeout = '2s';

explain (analyze, buffers, settings)
select
  product_id,
  domain_key,
  max(domain_label) as domain_label,
  value_key,
  max(display_label) as display_label,
  token,
  min(sort_order) as sort_order
from (
 WITH source_values AS MATERIALIZED (
         SELECT sf.product_id,
            COALESCE(o.size_domain, sf.domain_key) AS domain_key,
            sf.value_key AS source_value_key,
            sf.display_label AS source_display_label,
            sf.sort_order,
            o.size_value_overrides -> sf.display_label AS value_override,
                CASE
                    WHEN (o.size_value_overrides -> sf.display_label) IS NULL THEN sf.display_label
                    ELSE COALESCE(NULLIF(TRIM(BOTH FROM (o.size_value_overrides -> sf.display_label) ->> 'label'::text), ''::text), sf.display_label) ||
                    CASE
                        WHEN NULLIF(TRIM(BOTH FROM (o.size_value_overrides -> sf.display_label) ->> 'sizeGroup'::text), ''::text) IS NOT NULL THEN ' / '::text || TRIM(BOTH FROM (o.size_value_overrides -> sf.display_label) ->> 'sizeGroup'::text)
                        ELSE ''::text
                    END
                END AS normalization_input
           FROM public.catalog_size_facets_read_optimized_stage sf
             LEFT JOIN catalog_size_classification_overrides o ON o.product_id = sf.product_id
          WHERE COALESCE(o.exclude_from_size_filter, false) = false
        ), distinct_inputs AS MATERIALIZED (
         SELECT DISTINCT source_values_1.domain_key,
            source_values_1.normalization_input,
            source_values_1.source_value_key
           FROM source_values source_values_1
        ), input_features AS MATERIALIZED (
         SELECT distinct_inputs.domain_key,
            distinct_inputs.normalization_input,
            distinct_inputs.source_value_key,
            catalog_size_domain_label(distinct_inputs.domain_key) AS domain_label,
            catalog_strip_known_size_description(distinct_inputs.normalization_input) AS stripped_description,
            catalog_effective_size_value_key(distinct_inputs.source_value_key) AS original_key,
                CASE
                    WHEN distinct_inputs.domain_key = 'trousers'::text THEN catalog_normalize_trouser_size_value(distinct_inputs.normalization_input)
                    ELSE NULL::text
                END AS trouser_value_key
           FROM distinct_inputs
        ), normalized_inputs AS MATERIALIZED (
         SELECT input_features.domain_key,
            input_features.normalization_input,
            input_features.source_value_key,
            input_features.domain_label,
            input_features.stripped_description,
            input_features.original_key,
            input_features.trouser_value_key,
            catalog_effective_size_value_key(input_features.domain_key, COALESCE(input_features.stripped_description, input_features.normalization_input)) AS stripped_value_key,
            catalog_effective_size_value_key(input_features.domain_key, input_features.normalization_input) AS fallback_value_key
           FROM input_features
        ), normalized_components AS MATERIALIZED (
         SELECT normalized_inputs.domain_key,
            normalized_inputs.normalization_input,
            normalized_inputs.source_value_key,
            normalized_inputs.domain_label,
            normalized_inputs.stripped_description,
            normalized_inputs.original_key,
            normalized_inputs.trouser_value_key,
            normalized_inputs.stripped_value_key,
            normalized_inputs.fallback_value_key,
            COALESCE(normalized_inputs.trouser_value_key, normalized_inputs.stripped_value_key, normalized_inputs.fallback_value_key) AS value_key
           FROM normalized_inputs
        ), expanded_components AS MATERIALIZED (
         SELECT normalized_components.domain_key,
            normalized_components.normalization_input,
            normalized_components.source_value_key,
            normalized_components.domain_label,
            normalized_components.stripped_description,
            normalized_components.original_key,
            normalized_components.trouser_value_key,
            normalized_components.stripped_value_key,
            normalized_components.fallback_value_key,
            normalized_components.value_key,
            component.value_key AS facet_value_key
           FROM normalized_components
             CROSS JOIN LATERAL unnest(
                CASE
                    WHEN (normalized_components.domain_key = ANY (ARRAY['clothing'::text, 'shirts'::text, 'trousers'::text, 'suitwear'::text, 'underwear'::text, 'swimwear'::text, 'gloves'::text, 'headwear'::text, 'socks'::text])) AND normalized_components.value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)-(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'::text THEN string_to_array(normalized_components.value_key, '-'::text)
                    ELSE ARRAY[normalized_components.value_key]
                END) component(value_key)
        ), prepared_components AS MATERIALIZED (
         SELECT expanded_components.domain_key,
            expanded_components.normalization_input,
            expanded_components.source_value_key,
            expanded_components.domain_label,
            expanded_components.stripped_description,
            expanded_components.original_key,
            expanded_components.trouser_value_key,
            expanded_components.stripped_value_key,
            expanded_components.fallback_value_key,
            expanded_components.value_key,
            expanded_components.facet_value_key,
                CASE
                    WHEN expanded_components.value_key ~ '^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|xxxxl|xxxxxl|xxxxxxl|xxxxxxxl|xxxxxxxxl)$'::text THEN upper(expanded_components.value_key)
                    WHEN expanded_components.value_key ~ '^w[0-9]{2,3}-l[0-9]{2,3}$'::text THEN (('W'::text || "substring"(expanded_components.value_key, '^w([0-9]{2,3})'::text)) || ' × L'::text) || "substring"(expanded_components.value_key, '-l([0-9]{2,3})$'::text)
                    WHEN expanded_components.value_key = 'one-size'::text THEN 'Vienas dydis'::text
                    WHEN expanded_components.value_key IS NULL THEN NULL::text
                    WHEN expanded_components.stripped_description IS NOT NULL THEN expanded_components.value_key
                    WHEN expanded_components.value_key <> expanded_components.original_key THEN expanded_components.value_key
                    ELSE NULL::text
                END AS fixed_display_label,
            catalog_effective_size_sort_order(expanded_components.facet_value_key) AS facet_sort_order
           FROM expanded_components
        ), facet_components AS MATERIALIZED (
         SELECT prepared_components.domain_key,
            prepared_components.normalization_input,
            prepared_components.source_value_key,
            prepared_components.domain_label,
            prepared_components.stripped_description,
            prepared_components.original_key,
            prepared_components.trouser_value_key,
            prepared_components.stripped_value_key,
            prepared_components.fallback_value_key,
            prepared_components.value_key,
            prepared_components.facet_value_key,
            prepared_components.fixed_display_label,
            prepared_components.facet_sort_order
           FROM prepared_components
          WHERE prepared_components.facet_value_key IS NOT NULL
        )
 SELECT source_values.product_id,
    source_values.domain_key,
    facet_components.domain_label,
    facet_components.facet_value_key AS value_key,
        CASE
            WHEN facet_components.facet_value_key <> facet_components.value_key THEN upper(facet_components.facet_value_key)
            ELSE COALESCE(facet_components.fixed_display_label, COALESCE(NULLIF(TRIM(BOTH FROM source_values.value_override ->> 'label'::text), ''::text), source_values.source_display_label))
        END AS display_label,
    (source_values.domain_key || ':'::text) || facet_components.facet_value_key AS token,
    facet_components.facet_sort_order AS sort_order
   FROM source_values
     JOIN facet_components ON COALESCE(source_values.domain_key, ''::text) = COALESCE(facet_components.domain_key, ''::text) AND (source_values.domain_key IS NULL) = (facet_components.domain_key IS NULL) AND COALESCE(source_values.normalization_input, ''::text) = COALESCE(facet_components.normalization_input, ''::text) AND (source_values.normalization_input IS NULL) = (facet_components.normalization_input IS NULL) AND COALESCE(source_values.source_value_key, ''::text) = COALESCE(facet_components.source_value_key, ''::text) AND (source_values.source_value_key IS NULL) = (facet_components.source_value_key IS NULL)
) as optimized_effective_size
group by product_id, domain_key, value_key, token;

rollback;
