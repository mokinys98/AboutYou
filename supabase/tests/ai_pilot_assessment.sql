-- Read-only pilot assessment. Run each SELECT separately in the VPS Supabase SQL Editor.
-- No migration or write operation is performed by this file.

-- 1. Compare UTC daily accounting with request rows and the OpenAI Usage export.
select
  d.usage_day,
  d.actual_total as ledger_tokens,
  d.reserved_total as ledger_reserved_tokens,
  count(r.id) as request_rows,
  count(r.id) filter (where r.status = 'completed') as completed_requests,
  count(r.id) filter (where r.status = 'reconciled') as reconciled_requests,
  count(r.id) filter (where r.status in ('reserved', 'uncertain')) as unresolved_requests,
  count(r.id) filter (where r.error_code is not null) as requests_with_error_code,
  coalesce(sum(r.actual_tokens), 0) as request_tokens,
  round(avg(r.actual_tokens) filter (where r.actual_tokens is not null), 1) as average_request_tokens,
  max(r.actual_tokens) as maximum_request_tokens
from public.ai_daily_usage d
left join public.ai_control_requests r on r.usage_day = d.usage_day
where d.usage_day between date '2026-09-29' and date '2026-10-01'
group by d.usage_day, d.actual_total, d.reserved_total
order by d.usage_day;

-- 2. Count unique results and compare only reviewed fields with current-image AI results.
with reviewed as (
  select i.product_id, i.reviewed_at, a.product_id as ai_product_id,
    a.needs_review, a.confidence,
    i.human_color_family, i.human_color_shade, i.human_temperature,
    i.human_lightness, i.human_saturation, i.human_contrast,
    i.human_visual_pattern,
    a.dominant_color_family, a.dominant_color_shade, a.temperature,
    a.lightness, a.saturation, a.contrast, a.visual_pattern
  from public.ai_control_items i
  join public.products p on p.id = i.product_id
  left join public.product_ai_attributes a
    on a.product_id = i.product_id
   and a.source_image_url = p.image_urls->>0
), field_pairs as (
  select v.field, v.human_value, v.ai_value
  from reviewed r
  cross join lateral (values
    ('color_family', r.human_color_family, r.dominant_color_family),
    ('color_shade', r.human_color_shade, r.dominant_color_shade),
    ('temperature', r.human_temperature, r.temperature),
    ('lightness', r.human_lightness, r.lightness),
    ('saturation', r.human_saturation, r.saturation),
    ('contrast', r.human_contrast, r.contrast),
    ('visual_pattern', r.human_visual_pattern, r.visual_pattern)
  ) as v(field, human_value, ai_value)
  where r.reviewed_at is not null and r.ai_product_id is not null
)
select field,
  count(*) filter (where human_value is not null) as human_labels,
  count(*) filter (where human_value is not null and ai_value is not null) as comparable_labels,
  count(*) filter (where human_value is not null and ai_value = human_value) as exact_matches,
  round(100.0 * count(*) filter (where human_value is not null and ai_value = human_value)
    / nullif(count(*) filter (where human_value is not null and ai_value is not null), 0), 1) as exact_match_percent
from field_pairs
group by field
order by field;

-- 3. Dataset coverage, review flags, and physical storage (tables plus indexes).
select
  (select count(*) from public.ai_control_items) as control_set_items,
  (select count(distinct product_id) from public.ai_control_items) as unique_control_products,
  (select count(*) from public.ai_control_items where reviewed_at is not null) as reviewed_item_rows,
  (select count(*) from public.product_ai_attributes) as stored_ai_products,
  (select count(*) from public.product_ai_attributes where needs_review) as ai_needs_review,
  (select pg_size_pretty(pg_total_relation_size('public.product_ai_attributes'))) as ai_attributes_total_size,
  (select pg_size_pretty(pg_relation_size('public.product_ai_attributes'))) as ai_attributes_table_size,
  (select pg_size_pretty(pg_indexes_size('public.product_ai_attributes'))) as ai_attributes_indexes_size,
  (select pg_size_pretty(pg_total_relation_size('public.ai_control_requests'))) as requests_total_size;

-- AI fields are not yet in the public catalog read model. Index benefit and
-- catalog refresh duration require a real filter query and measured refresh.
