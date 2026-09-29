begin;

do $$
begin
  if (select count(*) from public.sources where slug = 'aboutyou-lt' and active) <> 1 then
    raise exception 'Expected exactly one active ABOUT YOU Lithuania source (slug: aboutyou-lt).';
  end if;
end;
$$;

create temporary table desired_mens_category_targets (
  label text primary key,
  url text not null unique,
  priority integer not null,
  initial_expected_total integer
) on commit drop;

insert into desired_mens_category_targets (label, url, priority, initial_expected_total)
values
  ('Drabužiai - Marškinėliai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/marskineliai-20324', 100, 19701),
  ('Drabužiai - Kelnės', 'https://www.aboutyou.lt/c/vyrams/drabuziai/kelnes-20330', 100, null),
  ('Drabužiai - Apatiniai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/apatiniai-20292', 100, null),
  ('Drabužiai - Džinsai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/dzinsai-20331', 100, null),
  ('Drabužiai - Striukės', 'https://www.aboutyou.lt/c/vyrams/drabuziai/striukes-20320', 100, null),
  ('Drabužiai - Marškiniai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/marskiniai-20319', 100, null),
  ('Drabužiai - Treningo dalys', 'https://www.aboutyou.lt/c/vyrams/drabuziai/treningo-dalys-20327', 100, null),
  ('Drabužiai - Maudymosi drabužiai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/maudymosi-drabuziai-20291', 100, null),
  ('Drabužiai - Megztiniai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/megztiniai-20322', 100, null),
  ('Drabužiai - Kostiumai ir švarkai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/kostiumai-ir-svarkai-20318', 100, null),
  ('Drabužiai - Paltai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/paltai-20321', 100, null),
  ('Batai - Sportbačiai', 'https://www.aboutyou.lt/c/vyrams/batai/sportbaciai-20345', 100, null),
  ('Batai - Atviri batai', 'https://www.aboutyou.lt/c/vyrams/batai/atviri-batai-20341', 100, null),
  ('Batai - Bateliai', 'https://www.aboutyou.lt/c/vyrams/batai/bateliai-20342', 100, null),
  ('Batai - Sportiniai batai', 'https://www.aboutyou.lt/c/vyrams/batai/sportiniai-batai-514809', 100, null),
  ('Batai - Batai ir auliniai batai', 'https://www.aboutyou.lt/c/vyrams/batai/batai-ir-auliniai-batai-20335', 100, null),
  ('Aksesuarai - Kepurės', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/kepures-20306', 100, null),
  ('Aksesuarai - Krepšiai ir kuprinės', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/krepsiai-ir-kuprines-517257', 100, null),
  ('Aksesuarai - Diržai', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/dirzai-20298', 100, null),
  ('Aksesuarai - Akiniai nuo saulės', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/akiniai-nuo-saules-72553', 100, null),
  ('Aksesuarai - Piniginės ir kosmetinės', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/pinigines-ir-kosmetines-23476', 100, null),
  ('Aksesuarai - Laikrodžiai', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/laikrodziai-69979', 100, null),
  ('Aksesuarai - Juvelyriniai dirbiniai', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/juvelyriniai-dirbiniai-83632', 100, null),
  ('Aksesuarai - Kaklaraiščiai ir aksesuarai', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/kaklaraisciai-ir-aksesuarai-101464', 100, null),
  ('Aksesuarai - Šalikai ir šaliai', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/salikai-ir-saliai-20309', 100, null),
  ('Aksesuarai - Pirštinės', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/pirstines-87814', 100, null),
  ('Aksesuarai - Aksesuarai būstui', 'https://www.aboutyou.lt/c/vyrams/aksesuarai/aksesuarai-bustui-688224', 100, null);

insert into public.sync_targets as existing (
  source_id,
  kind,
  label,
  url,
  enabled,
  priority,
  requested_at,
  expected_total,
  updated_at
)
select
  source.id,
  'category'::public.sync_target_kind,
  desired.label,
  desired.url,
  true,
  desired.priority,
  now(),
  desired.initial_expected_total,
  now()
from desired_mens_category_targets desired
cross join public.sources source
where source.slug = 'aboutyou-lt'
  and source.active
on conflict (url) do update
set source_id = excluded.source_id,
    kind = excluded.kind,
    label = excluded.label,
    enabled = true,
    priority = excluded.priority,
    requested_at = case
      when not existing.enabled then excluded.requested_at
      else existing.requested_at
    end,
    expected_total = coalesce(existing.expected_total, excluded.expected_total),
    updated_at = now();

-- Every ordinary group has one root collection part. The oversized
-- Marškinėliai group keeps its root part disabled and is collected through
-- the five smaller ABOUT YOU subcategories inserted below.
insert into public.catalog_target_parts as existing (
  target_id,
  part_key,
  url,
  enabled,
  priority,
  updated_at
)
select
  target.id,
  'root',
  target.url,
  target.label <> 'Drabužiai - Marškinėliai',
  100,
  now()
from public.sync_targets target
join desired_mens_category_targets desired on desired.url = target.url
on conflict (target_id, part_key) do update
set url = excluded.url,
    enabled = excluded.enabled,
    priority = excluded.priority,
    updated_at = now();

insert into public.catalog_target_parts as existing (
  target_id,
  part_key,
  url,
  enabled,
  priority,
  updated_at
)
select
  target.id,
  part.part_key,
  part.url,
  true,
  part.priority,
  now()
from public.sync_targets target
cross join (
  values
    ('laisvalaikio-marskineliai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/marskineliai/laisvalaikio-marskineliai-140199', 10),
    ('polo-marskineliai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/marskineliai/polo-marskineliai-20957', 20),
    ('marskineliai-ilgomis-rankovemis', 'https://www.aboutyou.lt/c/vyrams/drabuziai/marskineliai/marskineliai-ilgomis-rankovemis-20955', 30),
    ('berankoviai-marskineliai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/marskineliai/berankoviai-marskineliai-20325', 40),
    ('marskineliu-komplektai', 'https://www.aboutyou.lt/c/vyrams/drabuziai/marskineliai/marskineliu-komplektai-517255', 50)
) as part(part_key, url, priority)
where target.url = 'https://www.aboutyou.lt/c/vyrams/drabuziai/marskineliai-20324'
on conflict (target_id, part_key) do update
set url = excluded.url,
    enabled = excluded.enabled,
    priority = excluded.priority,
    updated_at = now();

commit;
