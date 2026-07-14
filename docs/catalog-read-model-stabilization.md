# Katalogo read modelio stabilizavimas

## Kodėl pakeitimas reikalingas

2026-07-14 katalogo skaitymai buvo perkelti į `catalog_items_read` ir
`catalog_item_facet_values_read` materialized view. Tai sumažino interaktyvių užklausų
kainą, bet pilnas refresh tapo brangia rašymo operacija. Incidento metu užfiksuota:

- `catalog_items_read`: 23 109 eilučių, 138 MB (82 MB duomenų ir 56 MB indeksų);
- `catalog_item_facet_values_read`: 610 076 eilučių, 121 MB (44 MB duomenų ir 77 MB indeksų);
- pilnas refresh truko 29,5–57,1 s;
- checkpoint truko iki 270 s, vienu ciklu sugeneruota iki maždaug 500 MB WAL;
- `claim_product_detail_batch` buvo iškviesta 5 104 kartus ir atliko daugiau kaip
  92,5 mln. `product_detail_sync` pirminio rakto patikrų, nes kiekvienam 25 produktų
  claim bandė iš naujo įterpti visus aktyvius produktus.

Prieš rollout užfiksuotos 23 109 katalogo eilutės pasirodė esančios pasenęs read
modelis. Pirmas sėkmingas rebuild paskelbė 47 045 eilutes — tiksliai tiek, kiek tuo metu
buvo aktyvių produktų — ir 878 694 facet eilutes. Tai buvo ankstesnių nepavykusių
refresh atstatymas, ne migracijos sukurti dublikatai.

Supabase Data API `authenticator` turi 8 s `statement_timeout`. DB I/O apkrovos metu
pirmas metadata claim peržengė šią ribą ir buvo nutrauktas su `57014`.

## Stabilizuota architektūra

Naujas produktas gauna `product_detail_sync` eilutę per `AFTER INSERT` triggerį.
Claim funkcija tik rezervuoja jau egzistuojančius darbus ir daugiau nebeskenuoja visų
aktyvių produktų papildomam seed'inimui.

`product_detail_sync.product_active` yra denormalizuotas ir palaikomas `products.active`
triggeriu. Tai leidžia daliniam claim indeksui atmesti neaktyvius produktus nebeskaitant
plačios `products` lentelės kiekvienam kandidatui. Produkcijos rollback benchmark po šio
pakeitimo: 49,9 ms 25 produktų paketui (tikslas <500 ms, hard limit <8 s).

Rollout patikroje atskira cron sesija ir rankinis procesorius patvirtino `busy`
atsakymą. Refresh metu pateikus naują request, vykdytojas užbaigė tik savo užfiksuotą
4 versiją (`requested_version=5`, `completed_version=4`), todėl naujas pakeitimas liko
dirty kitam ciklui. Stebėtos pilno refresh trukmės po migracijos: 46,6–73,8 s.

Read modelio atnaujinimas yra versijuojamas vienoje
`catalog_read_model_refresh_state` eilutėje:

1. `request_catalog_items_read_refresh()` padidina `requested_version` ir iškart grįžta.
2. Supabase Cron kas 5 minutes kviečia `process_catalog_items_read_refresh()`.
3. Procesorius naudoja `pg_try_advisory_xact_lock`, todėl antras vykdytojas nelaukia ir
   grąžina `busy`.
4. Sėkmingas refresh pažymi tik prieš darbą nuskaitytą versiją. Jei darbo metu gautas
   naujas request, `requested_version` lieka didesnė už `completed_version` ir kitas cron
   ciklas pakartoja refresh.
5. Klaida įrašoma į state lentelę, o dirty versija lieka pakartotiniam bandymui.

Sunkiai vidinei funkcijai taikomas 90 s `statement_timeout` ir 3 s `lock_timeout`.
`refresh_catalog_items_read()` lieka kaip senų klientų wrapperis, tačiau naujas kodas
kviečia tik request RPC. Nenaudotas 39 MB
`catalog_item_facet_values_read_group_idx` pašalintas; unikalus indeksas paliktas.

## Operacinė diagnostika

Dirty ir paskutinio bandymo būsena:

```sql
select *, requested_version > completed_version as dirty
from public.catalog_read_model_refresh_state;
```

Cron konfigūracija ir paskutiniai vykdymai:

```sql
select jobid, jobname, schedule, active, command
from cron.job
where jobname like 'catalog-read-model-refresh%';

select runid, jobid, status, start_time, end_time, return_message
from cron.job_run_details
where jobid in (
  select jobid from cron.job where jobname like 'catalog-read-model-refresh%'
)
order by start_time desc
limit 20;
```

Aktyvus refresh arba jo laukiamas DB resursas:

```sql
select pid, state, wait_event_type, wait_event, now() - query_start as running_for, query
from pg_stat_activity
where query ilike '%catalog_items_read_refresh%'
   or query ilike '%refresh materialized view%';
```

Claim ir refresh trukmės:

```sql
select calls, mean_exec_time, max_exec_time, total_exec_time, query
from extensions.pg_stat_statements
where query ilike '%claim_product_detail_batch%'
   or query ilike '%catalog_items_read_refresh%'
order by total_exec_time desc;
```

Rankinis neblokuojantis bandymas:

```sql
select public.request_catalog_items_read_refresh();
select public.process_catalog_items_read_refresh();
```

Galimos procesoriaus būsenos: `clean`, `busy`, `refreshed`, `failed`.

## Rollout ir patikra

1. Įsitikinti, kad nevyksta catalog/metadata sync ar rankinis materialized view refresh.
2. Išsaugoti katalogo eilučių, facet cache ir indeksų baseline.
3. Pritaikyti `stabilize_catalog_refresh` migraciją.
4. Patikrinti triggerį transakciniu testu su `rollback` ir claim funkcijos tekstą.
5. Claim benchmarką vykdyti transakcijoje su `rollback`; tikslas – mažiau nei 500 ms.
6. Patikrinti abu vardinius cron darbus ir sulaukti sėkmingo dirty versijos užbaigimo.
7. Įdiegti API Worker, push'inti `main` ir paleisti vieną metadata canary su 50 produktų.
8. Patikrinti PostgreSQL timeout logus, state lentelę, cron istoriją, API katalogą,
   facet'us ir Supabase security/performance advisors.

Istorinė produkcijos migracija `20260714191558_set_catalog_refresh_statement_timeout`
nustatė 60 s. Vėlesnė stabilizavimo migracija yra vienintelis aktualus šaltinis 90 s
ir 3 s limitams; istorinio failo turinio keisti negalima.

## Rollback

Jei cron vykdytojas kelia nenumatytą apkrovą, pirmiausia jį išjungti negrąžinant schemos:

```sql
select cron.alter_job(
  job_id := (select jobid from cron.job where jobname = 'catalog-read-model-refresh'),
  active := false
);
```

Senas suderinamumo RPC lieka prieinamas service role. Prireikus indeksą galima atkurti:

```sql
create index catalog_item_facet_values_read_group_idx
  on public.catalog_item_facet_values_read (facet_group, value, product_id);
```

Triggerio ir dirty state lentelės šalinti nereikia: jie nekeičia katalogo skaitymo
rezultatų ir leidžia saugiai tęsti metadata claim.

## Kitas etapas: inkrementinis read modelis

Pilną materialized view rebuild vėliau reikia pakeisti paprastomis read-model lentelėmis:

- registruoti pasikeitusių produktų ID;
- vienu batch upsert'inti tik jų katalogo eilutes;
- ištrinti ir iš naujo įrašyti tik jų facet reikšmes;
- po batch invaliduoti kontekstinį facet cache;
- migraciją atlikti su dvigubu rašymu ir rezultatų palyginimu prieš API perjungimą.

Šį etapą pradėti, jei po stabilizavimo p95 refresh išlieka virš 45 s, kartojasi DB I/O
timeout'ai, katalogo apimtis ženkliai auga arba 5 minučių atsilikimas tampa nepriimtinas.
