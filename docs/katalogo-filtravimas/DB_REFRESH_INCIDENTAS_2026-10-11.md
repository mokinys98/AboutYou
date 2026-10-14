# DB bloat ir katalogo refresh incidentas — 2026-10-11

## Būsena

- Negyvų eilučių valymas `public.catalog_items_read` **sėkmingai įvykdytas** naudotojo VPS.
- Lentelės heap dydis sumažėjo nuo maždaug 38 GB iki maždaug 1,4 GB; po valymo bendras lentelės ir indeksų dydis buvo apie 6,6 GB.
- Katalogo refresh problema **neišspręsta**: po valymo naujas ciklas vis tiek baigėsi `statement timeout`, dabar jau `effective_size_membership` fazėje.
- Nėra patvirtinimo, kad metadata sync workflow po eilės reset buvo paleistas ar sėkmingai apdorojęs naujus įrašus.
- VPS pakeitimų Codex neatliko. `VACUUM` komandą VPS terminale paleido naudotojas; Codex tik patikrino rezultatą per read-only DB tunelį.

Visi žemiau pateikti DB laikai yra UTC. Eilučių skaičiai `pg_stat_user_tables` yra įverčiai, ne tikslus `COUNT(*)`.

## Eiga ir įrodymai

### Metadata eilės reset

Naudotojas paleido vienkartinį `supabase/manual/20261010_requeue_expired_metadata_leases.sql` SQL Editor. Po jo pateikta patikra rodė:

- `expired_processing_leases = 0`;
- `due_pending = 18 952` (buvo 18 922; 30 pasibaigusių lease grąžintos į eilę);
- `due_retryable = 8 617`.

Šis veiksmas ištrynė ne produkto duomenis, o tik išvalė 30 pasibaigusių lease ir grąžino jų eilutės būseną į `pending`. Vėlesnio sync workflow rezultato šiame užraše nėra.

### Pirmas VACUUM bandymas ir shared memory

Pirmas `VACUUM (VERBOSE, ANALYZE) public.catalog_items_read` nutrūko su:

```text
could not resize shared memory segment ... to 8388608 bytes: No space left on device
CONTEXT: while scanning block 2130431 of relation "public.catalog_items_read"
```

VPS patikros rezultatai:

- hosto `/dev/shm`: 5,9 GB, tuo metu laisva visa talpa;
- PostgreSQL konteinerio `/dev/shm`: 64 MB, naudota 2,2 MB, laisva 61,8 MB;
- konteinerio `ShmSize`: 67 108 864 baitai (64 MiB).

VPS read-only patikra patvirtino PostgreSQL 17.6 ir `dynamic_shared_memory_type = posix`. Šie duomenys rodo mažą konteinerio shared-memory limitą, tačiau po nesėkmės atliktas `df` neįrodo, kad būtent tuo momentu visa talpa buvo užimta.

### Sėkmingas VACUUM be lygiagretaus index valymo

Naudotojas paleido:

```bash
docker exec supabase-db psql -U postgres -d postgres -c 'VACUUM (VERBOSE, PARALLEL 0) public.catalog_items_read;'
```

Komanda baigėsi `VACUUM` pranešimu. Išvestyje nurodyta:

- vykdymo laikas apie **1 457 s** (24 min. 17 s);
- nuskaityta **5 032 124** heap puslapių;
- pašalinta **4 899 370** puslapių, liko **132 754**;
- pašalinta **14 093 528** eilučių versijų;
- **0** eilučių liko „dead but not yet removable“ būsenoje;
- reikėjo 2 index scan; iš indeksų pašalinta **24 337 846** negyvų item ID.

Išvesties pranešimai `suspending truncate due to conflicting lock request` valymo nesustabdė: puslapiai buvo trumpinami toliau, o VACUUM sėkmingai užsibaigė. Pagal 8 KiB PostgreSQL puslapį pašalinti puslapiai sudaro apie **37,4 GiB**.

### Dydžiai po valymo ir atsinaujinęs refresh timeout

2026-10-10 23:09:55 UTC read-only patikra rodė:

| Rodiklis | Reikšmė |
|---|---:|
| `catalog_items_read` gyvų eilučių įvertis | 105 475 |
| negyvų eilučių įvertis | 647 944 |
| `last_vacuum` | 2026-10-10 22:29:17 UTC |
| heap | 1 373 MB |
| indeksai | 5 235 MB |
| bendra lentelės vieta | 6 609 MB |

Kita patikra po kelių sekundžių rodė 1 407 MB heap, 5 235 MB indeksų, 6 642 MB iš viso ir 740 661 negyvų eilučių įvertį. Statistikos įverčiai ir dydžiai kinta; reikšmės nebūtinai reiškia, kad pats VACUUM nepavyko.

2026-10-10 23:10:05 UTC `catalog_read_model_refresh_state` rodė:

- `requested_version = 2632`, `completed_version = 2476`, atsilikimas **156**;
- `last_status = failed`, trukmė **300 365 ms**;
- ciklas prasidėjo **23:05:03.401 UTC**, baigėsi **23:10:03.768 UTC**;
- klaidos fazė: `invalidate_catalog_facets_cache`; jos viduje `effective_size_membership` baigėsi po **131 859 ms** su `canceling statement due to statement timeout`;
- patikros metu aktyvių DB užklausų nebuvo.

Taigi `catalog_items_read` bloat reikšmingai sumažėjo, bet refresh grandinė tebėra nestabili. Negyvų eilučių įverčio padidėjimas po VACUUM laike sutampa su nauju nepavykusiu refresh ciklu; ryšys tikėtinas, bet vien šis sutapimas neįrodo, kad visos naujos negyvos versijos atsirado būtent dėl šio bandymo.

## Dabartinė lėta fazė

VPS klaidos tekste vidinė `effective_size_membership` fazė atitinka:

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY
  public.catalog_effective_size_membership_read;
```

Lokalioje migracijoje [20261007200200_instrument_catalog_refresh_phase_timings.sql](../../supabase/migrations/20261007200200_instrument_catalog_refresh_phase_timings.sql) ši komanda yra `invalidate_catalog_facets_cache()` pradžioje. Materializuotas modelis skaičiuojamas iš `catalog_size_facets_read_effective`, grupuojant pagal produkto ID, dydžio domeną ir dydžio rakto laukus.

Po incidento modelio read-only statistika buvo apie 372 333 gyvų eilučių, 3 496 negyvų eilučių, 54 MB heap, 36 MB indeksų ir 90 MB iš viso. Mažas galutinio materializuoto vaizdo dydis savaime nereiškia, kad jo šaltinio užklausa pigi: šaltinio vaizde atliekama dydžių normalizacija, išraiškų skaičiavimas, galimas dydžių išplėtimas ir grupavimas. Tai tikrintina hipotezė, ne patvirtinta lėto plano priežastis.

## Rytojaus siūlomas tęsinys

1. **Daugiau nebekartoti VACUUM dabar.** Sėkmingas valymas patvirtintas; `VACUUM FULL` ir aklas `REINDEX` nenaudoti. Indeksai vis dar sudaro apie 5,2 GB, bet vien dydis neįrodo, kad juos reikia perkurti.
2. **Užfiksuoti naują read-only atskaitos tašką**: refresh versijų skirtumą, paskutinę klaidą ir laiką, `catalog_items_read` bei `catalog_effective_size_membership_read` dydžius / eilučių įverčius, autovacuum laikus, konteinerio `/dev/shm` ir aktyvias DB užklausas.
3. **Patikrinti VPS įdiegtą tikrą apibrėžimą** `pg_get_viewdef('public.catalog_size_facets_read_effective'::regclass, true)` bei `catalog_effective_size_membership_read` matview apibrėžimą. Palyginti jį su vietinėmis migracijomis, nes repo failas vienas pats neįrodo, koks kodas dabar įdiegtas VPS.
4. **Pirmiausia gauti neanalitinį planą**, tada ramios apkrovos lange atlikti apribotą `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` šaltinio SELECT. `ANALYZE` vykdo realią užklausą ir gali apkrauti DB, todėl nustatyti trumpą `statement_timeout` ir nestartuoti refresh rankiniu būdu diagnostikos metu.
5. **Pagal planą tikrinti** skenavimo eilučių neatitikimus, `catalog_size_facets_read` ir override lentelių indeksus, funkcijų (ypač normalizavimo) skaičių per eilutę, grupavimo/sortavimo spill į temp failus ir nested loop eilučių sprogimą. Keisti tik patvirtintą brangiausią etapą.
6. **Nedidinti 5 min. timeout kaip pirmo taisymo.** Ciklas jau trunka apie 300 s ir nauja klaida dabar atsiranda `effective_size_membership` fazėje. Timeout didinimas galėtų pailginti apkrovą ir dar labiau atitolinti ciklus.
7. **Po pataisos stebėti bent kelis natūralius ciklus**: `last_status` ne `failed`, `completed_version` pasiveja `requested_version`, dead tuple įverčiai neauga sparčiau už valymą, API katalogo/facetų endpointai atsako sėkmingai.
8. **Metadata sync tęsti atskirai ir ribotai.** Eilės resetas patvirtino 30 expired lease atkūrimą, tačiau 18 952 pending ir 8 617 due retryable įrašai yra didelė eilė. Pirma patikrinti paskutinį workflow rezultatą, tada paleisti 50 produktų canary su serializuotu, lėtu tempu; nepaleisti 10k darbo kaip „reset“.

## Faktai ir išvados

- **Patvirtinta:** `VACUUM (VERBOSE, PARALLEL 0)` pavyko ir pašalino milijonus tuple versijų bei didžiąją dalį heap puslapių.
- **Patvirtinta:** iškart po valymo `catalog_items_read` bendras dydis buvo apie 6,6 GB, iš kurių apie 5,2 GB indeksai.
- **Patvirtinta:** katalogo refresh po to vėl baigėsi statement timeout `effective_size_membership` fazėje; versijų atsilikimas buvo 156.
- **Hipotezė:** brangiausia vieta yra efektyvių dydžių šaltinio view normalizavimo / grupavimo kelias. Tam būtinas VPS apibrėžimas ir vykdymo planas.
- **Nežinoma:** ar naujas refresh timeout sukūrė visus po VACUUM matytus ~0,65–0,74 mln. dead tuple įvertį; ar metadata workflow jau buvo paleistas po eilės reset.

## 2026-10-11 10:59–11:46 UTC read-only tęsinys

Codex per leistiną PostgreSQL tunelį užfiksavo, kad po vakarykščio valymo
`catalog_items_read` vėl sparčiai didėja. 10:59 UTC `requested_version = 2674`,
`completed_version = 2476` (198 versijų skirtumas), heap buvo
23 375 568 896 B, indeksai 5 495 758 848 B, o `n_dead_tup` įvertis
13 668 838. 11:44 UTC heap jau buvo 24 645 599 232 B, `n_dead_tup`
14 420 866. Autovacuum šiam vaizdui paskutinį kartą fiksuotas 2026-10-09
10:53:59 UTC, nors serverio `autovacuum` įjungtas ir vaizdas neturi jo
išjungiančių `reloptions`. Šie skaitikliai yra įverčiai; fiziniai dydžiai
patvirtina naują augimą po sėkmingo VACUUM.

Naujausi natūralūs ciklai visi išnaudojo apie 300 s: 11:25:58–11:31:02 UTC
baigėsi `catalog_items_read_analyze` fazėje po 3 686 ms joje; 11:31:02–11:36:02
baigėsi `catalog_item_facet_values_read` fazėje po 28 445 ms joje;
11:36:02–11:41:03 po 25 926 ms toje pačioje fazėje;
11:41:03–11:46:03 po 14 634 ms toje pačioje fazėje. Kadangi 5 min. limitas
taikomas visam ciklui, ankstesnė `catalog_items_read` fazė suvartojo beveik
visą biudžetą. `completed_version` per šias patikras liko 2476.

VPS `pg_get_viewdef` sutampa su pagrindine vietinės migracijos schema:
`catalog_items_read` skaičiuojamas iš `products`, `offers`, kategorijų ir
`brand_tiers`, o `catalog_item_facet_values_read` išplečia 13 facet grupių iš
`catalog_items_read` ir pašalina dublikatus. Pagrindinio vaizdo
`REFRESH MATERIALIZED VIEW CONCURRENTLY` vis dar įdiegtas. PostgreSQL 17
concurrent refresh taiko `DELETE` / `INSERT` palyginimo kelią, o jo užraktas
nesuderinamas su VACUUM to paties vaizdo metu. Beveik nepertraukiami 5 min.
bandymai kartu su nepasikeitusia autovacuum data paaiškina augimo mechanizmą;
tiksli kiekvienos dead tuple kilmė atskirai neįrodyta.

Šaltinio užklausos `EXPLAIN` be `ANALYZE` gautas, tačiau tikro vykdymo
`EXPLAIN (ANALYZE, BUFFERS)` dar **nepaleistas**: per 3 min. stebėjimą nebuvo
nė 10 s intervalo be refresh užrakto. Be to, `log_min_messages = fatal`
(nustatyta paleidimo komandoje), todėl anksčiau įdiegtų `RAISE LOG`
fazių įrašų `docker logs` nerodo. SQL Editor `postgres` vaidmuo neturi teisės
keisti šio supernaudotojo parametro; globalių teisių ar logavimo nustatymų
keisti neplanuojama.

Diagnostikos langui paruoštas vienkartinis
[cron pauzės scenarijus](../../supabase/manual/20261011_pause_catalog_refresh_for_diagnostics.sql),
[grąžinimo scenarijus](../../supabase/manual/20261011_resume_catalog_refresh_after_diagnostics.sql)
ir atskiros [pauzės](../../supabase/tests/verify_catalog_refresh_paused_read_only.sql)
bei [grąžinimo](../../supabase/tests/verify_catalog_refresh_resumed_read_only.sql)
read-only patikros. **VPS jų taikymas dar nepatvirtintas.** Gavus SQL Editor
sėkmės išvestį, reikia sulaukti, kol nebeliks vykstančio cron ciklo ir
advisory / materializuotų vaizdų refresh užraktų. Tada po vieną matuoti
abiejų šaltinių SELECT su trumpu `statement_timeout`. Galutinės našumo
migracijos dar nėra, nes šie realūs planai būtini saugiam pasirinkimui.

## 2026-10-11 SQL Editor cron pauzės klaida

Pirmas rankinis pauzės scenarijus SQL Editor baigėsi `ERROR 42501: permission denied for table job` ties `UPDATE cron.job`. Pauzė **nepatvirtinta**; šio failo ir jo grąžinimo poros kartoti negalima. Vien tik klaidos tekstas nepatvirtina galutinės `cron.job.active` reikšmės, todėl būsena tikrinama atskiru read-only scenarijumi.

Leistinu read-only tuneliu nustatyta: `cron.job` priklauso `supabase_admin`; `postgres` vaidmuo turi `SELECT`, bet neturi `UPDATE` šios lentelės teisės. Įdiegta `pg_cron` 1.6.4 turi `cron.alter_job(job_id bigint, ..., active boolean)`, ir `postgres` turi `EXECUTE` teisę. Oficialus 1.6.4 kodas leidžia funkcijai keisti darbo `active` tik tada, kai kviečiantysis yra to darbo `username` (arba supernaudotojas). SQL Editor vaidmuo ir konkretaus darbo `username` dar turi būti patvirtinti [atskira read-only diagnostika](../../supabase/tests/diagnose_catalog_refresh_cron_permissions_read_only.sql). Teisių plėtimas ar savininko keitimas nesiūlomas.

Gautame SQL Editor rezultato fragmente matyti vienas `catalog-read-model-refresh` darbas: `jobid = 1`, grafikas `*/5 * * * *`, komandoje `process_catalog_items_read_refresh()`, `username = postgres`, `active = true`. Pagal šiuos duomenis parengta nauja pauzės ir grąžinimo failų versija su `cron.alter_job(..., active => ...)` ir apsauginėmis darbo tapatybės bei būsenos patikromis. **Nauja versija VPS dar nepritaikyta.** Ankstesnis `UPDATE cron.job` bandymas lieka nepavykęs; naujos versijos sėkmę reikia patvirtinti atskira read-only patikra.

## 2026-10-11 13:08–15:45 UTC pauzės ir šaltinių planų tęsinys

Vartotojo pateikta atskira read-only SQL Editor patikra 13:08:40 UTC parodė `cron.job.active = false`, tačiau `refresh_advisory_lock_now = true` ir `refresh_lock_now = true`. Pauzės scenarijaus sėkmės išvestis atskirai nepateikta; patikros rezultatas patvirtina tik nuotolinę būseną. Codex read-only tuneliu užraktą stebėjo iki 13:11:14 UTC, kai jis išnyko. 13:11:22 UTC vėl buvo 0 refresh užraktų. Šaltinių matavimai atlikti tik be šių užraktų, kiekvienas `BEGIN READ ONLY` transakcijoje su 2 s `lock_timeout`.

- [`catalog_items_read` tikras planas](20261011_catalog_items_read_source_plan.json): 13:11:30 UTC, `statement_timeout = 30s`, vykdymas 7 748 ms, 104 922 rezultato eilutės; 17 361 laikinas blokas įrašytas agregavimo / rūšiavimo metu.
- Pirmas `catalog_item_facet_values_read` tikro plano bandymas su 30 s riba baigėsi `57014 statement timeout` ir neišsaugojo plano. [Neanalitinis planas](20261011_catalog_item_facet_values_read_estimated_plan.json) prognozavo apie 308 mln. eilučių ankstesniame taške.
- [`catalog_item_facet_values_read` tikras planas](20261011_catalog_item_facet_values_read_source_plan.json): 15:42:39 UTC, `statement_timeout = 60s`, vykdymas 12 096 ms, 2 405 253 rezultato eilutės. Planuoklis vertino 144 653 652 eilučių, t. y. apie 60 kartų daugiau. Iš `catalog_items_read` perskaityta apie 132 754 bendros atminties blokų.
- 15:43 UTC `catalog_items_read` heap jau buvo apie 1 037 MB, indeksai apie 5 273 MB. `last_autovacuum = 2026-10-11 14:01:21 UTC`. `pg_class.reltuples` ir `pg_stat_all_tables.n_live_tup` tebebuvo apie 1,24 mln., nors tiesioginis read-only `count(*)` rodė tik 104 588 gyvų eilučių. Pirmojo facet bandymo ir vėlesnio 12 s rezultato skirtumą geriausiai paaiškina fizinio heap sumažėjimas po autovacuum; vien talpyklos įšilimo hipotezė nepakankama.
- 15:43 UTC refresh būklė tebebuvo `requested_version = 2693`, `completed_version = 2476`, `last_status = pending`; tai **217 versijų atsilikimas**. Paskutinė išsaugota nesėkmė buvo 300 338 ms ciklas, baigęsis facet fazėje po 15 747 ms.
- Vienas papildomas ribotas read-only palyginimas su gyvu pagrindinio vaizdo šaltiniu rado 104 928 šaltinio eilutes, 1 247 naujus ID ir 91 805 produktus, kurių `updated_at` skiriasi nuo materializuoto vaizdo. Tai paaiškina, kodėl pirmasis pasivijimo refresh turės daug pakeitimų; tie skaičiai nėra naujų pakeitimų per vieną 5 min. ciklą įvertis.

Šaltinių SELECT trukmė iš viso yra dešimčių sekundžių eilės, o nepavykstantis visas refresh pasiekia 300 s. Taigi šaltinių planų optimizavimas vienas pats negarantuotų 5 min. ciklo. Po autovacuum statistika yra smarkiai pasenusi; paruoštas vienkartinis [`ANALYZE` SQL Editor failas](../../supabase/manual/20261011_analyze_catalog_items_read_after_vacuum.sql) ir [atskira read-only patikra](../../supabase/tests/verify_catalog_items_read_analyze_read_only.sql). **Jie dar nepritaikyti VPS.** Po šio žingsnio būtina iš naujo patikrinti planuoklio įvertį ir suplanuoti vienkartinį saugų pasivijimą prieš grąžinant 5 min. cron. Nuolatinės našumo migracijos poveikio kol kas negalima patvirtinti.

## Paruoštas VPS SQL Editor handoff (dar nepritaikytas)

1. Vienkartinis [`ANALYZE`](../../supabase/manual/20261011_analyze_catalog_items_read_after_vacuum.sql), tada [read-only statistikos patikra](../../supabase/tests/verify_catalog_items_read_analyze_read_only.sql). Tikslas – `reltuples` priartinti prie ~105 tūkst. gyvų eilučių prieš pasivijimą.
2. [Migracija `20261011160000_tune_catalog_read_model_autovacuum.sql`](../../supabase/migrations/20261011160000_tune_catalog_read_model_autovacuum.sql) nustato 500 + 2% vacuum ir analyze slenksčius `catalog_items_read` ir `catalog_item_facet_values_read`; [read-only patikra](../../supabase/tests/verify_catalog_read_model_autovacuum_read_only.sql) turi grąžinti dvi eilutes su `expected_options_present = true`. Peržiūra materialių SQL defektų nerado. Slenksčiai padeda kontroliuoti pūtimąsi tik tada, kai tarp refresh transakcijų autovacuum gali gauti reikalingą užraktą.
3. Po sėkmingų 1–2 žingsnių vienas [ribotas pasivijimo bandymas](../../supabase/manual/20261011_catch_up_catalog_refresh_once.sql) su 12 min. `statement_timeout`, kol 5 min. cron sustabdytas; po jo [atskira read-only patikra](../../supabase/tests/verify_catalog_refresh_catch_up_read_only.sql). Prieš bet kokį kartojimą reikia peržiūrėti JSON rezultatą ir statistiką.
4. 5 min. cron grąžinamas tik po sėkmingo pasivijimo ir įvertinus jo trukmę. Net vienas sėkmingas ciklas neįrodo, kad jis **visada** truks mažiau nei 5 min.; reikalingi keli natūralūs ciklai ir dydžių / dead tuple stebėsena.

Joks iš šių naujų VPS veiksmų dar nepatvirtintas kaip pritaikytas. Bet kokia SQL Editor klaida reiškia nesėkmingą žingsnį ir reikalauja naujos read-only diagnostikos prieš kartojimą.

## 2026-10-11 18:08–18:12 UTC ANALYZE patvirtinimas

Vartotojas pateikė sėkmingą SQL Editor `ANALYZE public.catalog_items_read` vykdymą. Atskiroje read-only patikroje 18:10:50 UTC matėsi `refresh_job_active = false`, `estimated_rows = 105504`, `live_rows = 104588`, `heap_size = 1037 MB`, `last_analyze = 18:07:58 UTC`, `refresh_lock_now = false`. Šis rankinis veiksmas ir jo read-only patikra patvirtinti atskirai.

Po ANALYZE Codex leistinu read-only tuneliu 18:11:36 UTC dar kartą išmatavo [facet šaltinio planą](20261011_catalog_item_facet_values_read_post_analyze_plan.json): 13 112 ms, 2 405 253 faktinės eilutės ir 12 343 968 planuotos eilutės. Įvertis sumažėjo nuo 144 653 652, bet lieka maždaug 5 kartus per didelis. Užraktų nebuvo; `requested_version = 2703`, `completed_version = 2476`, atsilikimas 227. 5 min. cron dar neturi būti grąžinamas, kol nebus atliktas kontroliuojamas pasivijimas.

## 2026-10-11 18:13 UTC autovacuum migracijos patvirtinimas

Vartotojas pateikė SQL Editor sėkmingo [migracijos `20261011160000_tune_catalog_read_model_autovacuum.sql`](../../supabase/migrations/20261011160000_tune_catalog_read_model_autovacuum.sql) vykdymo ekraną ir atskirą read-only rezultatą: `catalog_items_read` ir `catalog_item_facet_values_read` abiem `expected_options_present = true`, visos keturios reloptions yra 500 + 0.02. Taigi nuotolinis pritaikymas ir read-only patikra patvirtinti atskirai. Tai nėra pasivijimo ar 5 min. ciklo sėkmės įrodymas.

Papildoma Codex read-only patikra 18:13:54 UTC: `requested_version = 2703`, `completed_version = 2476`, atsilikimas 227, `last_status = pending`, pagrindinio MV 0 refresh užraktų, `reltuples = 105504`, tikras `count(*) = 104588`, `n_dead_tup = 0`, heap 1 087 520 768 B. Tai atitinka paruošto vienkartinio pasivijimo failo apsaugines statistikos ir užrakto sąlygas; cron aktyvumo sąlygą pats failas dar kartą patikrins prieš darbą.

## 2026-10-11 18:16–18:29 UTC vienkartinis pasivijimas nepavyko

SQL Editor vietoje JSON rezultato parodė savo klaidos formato validacijos tekstą (`code` ir `formattedError` buvo `undefined`). Codex read-only tuneliu nustatė, kad PostgreSQL užklausa po šio UI atsako vis dar veikė: PID 1356948 laikė `catalog_items_read` `ExclusiveLock` ir refresh advisory užraktą. Nuo 18:20 iki 18:28 UTC atliktos stebėjimo patikros rodė `completed_version = 2476` ir tą patį PID. Iki 18:28:55 UTC užraktai išnyko.

Galutinė read-only būsena 18:29:05 UTC: `last_status = failed`, `last_duration_ms = 720439`, `refresh_started_at = 18:16:46`, `refresh_completed_at = 18:28:46`, `requested_version = 2704`, `completed_version = 2476` (228 versijų atsilikimas). Tikslus `last_error`: `57014: catalog refresh phase invalidate_catalog_facets_cache after 260974 ms: catalog refresh phase effective_size_membership after 260626 ms: canceling statement due to statement timeout`. Taigi pirmesnės fazės bendrai suvartojo apie 459 s, o `effective_size_membership` fazė dar 261 s; 12 min. riba pasiekta ne dėl SQL Editor pranešimo. **Pasivijimas nepavyko, cron neturi būti grąžinamas ar bandymas aklai kartojamas.**

Po nepavykusios transakcijos pagrindinio MV `n_dead_tup` įvertis ~93 095, facet-values MV ~79 040, nors heap dydis dar ~1 087 MB. Šie skaitikliai yra įverčiai. Autovacuum slenksčių migracija įdiegta, bet naujus dead tuples jis gali šalinti tik gavęs užraktą. `catalog_size_facets_read` yra apie 40 MB heap ir 99 MB indeksų; `catalog_effective_size_membership_read` apie 57 MB heap ir 38 MB indeksų. Mažas tikslo dydis neatmeta brangaus šaltinio normalizavimo.

Codex read-only `EXPLAIN ANALYZE` efektyvių dydžių šaltiniui negalėjo vykdyti, nes `codex_reader` neturi `EXECUTE` teisių `catalog_normalize_trouser_size_value` bei susijusioms normalizavimo funkcijoms. Jų savininkas `postgres` turi teises, todėl paruoštas [atskiras read-only SQL Editor planas](../../supabase/tests/explain_catalog_effective_size_membership_source_read_only.sql) su 30 s `statement_timeout`. Teisių plėtimas nesiūlomas.

## 2026-10-11 efektyvių dydžių šaltinio 30 s timeout ir optimizavimo handoff

Vartotojo SQL Editor vykdytas read-only `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` pilnam `catalog_effective_size_membership_read` šaltiniui baigėsi pranešimu `SQL query ran into an upstream timeout`; vykdymo planas negrąžintas. Šio bandymo nekartojame su ilgesniu timeout.

Codex leistinu read-only tuneliu nustatė, kad dabartinis `catalog_size_facets_read` šaltinis turi 375 751 eilutę, bet tik 2 503 skirtingus `(domain_key, normalization_input, source_value_key)` trejetus. Šie trys laukai dabartinėje imtyje nėra NULL. Įdiegtas VPS `catalog_size_facets_read_effective` apibrėžimas ir jo savininkas (`postgres`) patikrinti; pilno `pg_get_viewdef(..., true)` MD5 yra `713f5e880cbea0cac534b24f54a7be02`. Priklausomas materializuotas vaizdas skaito visą view; dvi aptiktos SQL funkcijos, kurios jį naudoja, taip pat skaito visą view.

Paruošta [migracija `20261011190000_deduplicate_effective_size_normalization.sql`](../../supabase/migrations/20261011190000_deduplicate_effective_size_normalization.sql). Ji nekeičia materializuotų duomenų ir nevykdo refresh; normalizavimo funkcijas skaičiuoja tik kiekvienam skirtingam įėjimui, o po to sujungia atgal su visomis šaltinio eilutėmis. NULL semantiką išsaugo atskiros `coalesce` reikšmių ir `IS NULL` požymių lygybės. Pirmas `IS NOT DISTINCT FROM` jungimo variantas buvo atmestas, nes planuoklis jam rinkosi labai brangų Nested Loop. Read-only funkcijų nekviečiančio pataisyto jungimo `EXPLAIN ANALYZE` grąžino visas 375 751 eilutes per 3 179 ms (Merge Join, įskaitant šaltinio nuskaitymą ir skirtingų įėjimų radimą). Tai **nėra** pilno normalizavimo arba refresh trukmės matavimas. Nepriklausoma SQL peržiūra nerado semantinio defekto; lieka rizika, kad tiesioginis vieno produkto filtravimas per šį view po migracijos turėtų nuskaityti visą šaltinį.

VPS migracija **dar nepritaikyta**. Po vartotojo sėkmingo SQL Editor vykdymo atskira [read-only diegimo patikra](../../supabase/tests/verify_effective_size_normalization_view_read_only.sql) turi grąžinti vieną eilutę su `cron_active=false` ir visais keturiais optimizavimo požymiais `true`. Tada atskiras [30 s read-only šaltinio planas](../../supabase/tests/explain_catalog_effective_size_membership_after_optimization_read_only.sql) turi parodyti tikrą trukmę. Tik jeigu planas telpa į ribą, galima svarstyti vieną kontroliuojamą pasivijimą su sustabdytu cron. Ankstesnio nesėkmingo pasivijimo pirmosios fazės jau sunaudojo apie 459 s, todėl šios migracijos poveikis visam ciklui dar neįrodytas. 5 min. cron lieka sustabdytas.

## 2026-10-11 18:40–18:43 UTC optimizuoto view diegimo patikra

Vartotojo pateikta SQL Editor read-only patikra 18:40:34 UTC grąžino vieną eilutę: `cron_active=false`, savininkas `postgres`, `source_materialized=true`, `distinct_inputs_materialized=true`, `normalized_inputs_materialized=true`, `view_optimized=true`. Codex read-only tuneliu 18:43:13 UTC papildomai patvirtino, kad VPS `pg_get_viewdef` MD5 pasikeitė iš priešmigracinio `713f5e880cbea0cac534b24f54a7be02` į `3779920dbe0f68902912fb2dca60b6b7`; tuo metu aktyvaus refresh nebuvo, `requested_version=2705`, `completed_version=2476`, `last_status=pending`. Vadinasi, naujas view apibrėžimas yra VPS. Atskiras migracijos SQL Editor sėkmingo vykdymo pranešimas dar nepateiktas, o pilno naujo šaltinio trukmė dar neišmatuota. Cron negrąžinamas.

Po pakeitimo vartotojo SQL Editor read-only pilnas `EXPLAIN ANALYZE` dar kartą baigėsi `SQL query ran into an upstream timeout`, plano negrąžino. Codex tunelio patikra po to nematė aktyvios tokios užklausos; refresh būsena nepasikeitė. `codex_reader` neturi `EXECUTE` teisių normalizavimo funkcijoms, todėl net ir `EXPLAIN` be `ANALYZE` šiam view grąžina `permission denied for function catalog_strip_known_size_description`. Teisių nekeisime. Paruoštas mažesnis [read-only `count(*)` planas](../../supabase/tests/diagnose_effective_size_view_count_read_only.sql) su 20 s timeout, kuris atskirs normalizavimo / išplėtimo kainą nuo visos narystės agregacijos ir projekcijos. Kol kas negalima daryti išvados, kad optimizavimas sutrumpino pilną šaltinį iki 30 s.

## 2026-10-11 papildomas `count(*)` planas ir komponentų migracija

Vartotojo pateiktas [read-only `count(*)` planas](../../supabase/tests/diagnose_effective_size_view_count_read_only.sql) baigėsi per **6 595,774 ms** ir per view išvedė **381 391** eilutę. `source_values` turėjo 375 751 eilutę, `distinct_inputs` — 2 503. `input_features` užtruko iki ~763 ms, `normalized_inputs` iki ~2 778 ms, 375 751 eilučių Merge Join iki ~5 363 ms. `unnest` Function Scan buvo kviečiamas 375 751 kartą; planas neskaičiavo galutinio `display_label` bei `sort_order`, todėl pilno šaltinio >30 s rezultatas su šiuo 6,6 s matavimu neprieštarauja. Codex atskirai read-only tuneliu išmatavo grupavimą jau materializuotam `catalog_effective_size_membership_read`: 372 333 eilutės per **1 165 ms**. Bazinės `catalog_size_sort_order(value_key)` funkcijos vykdymas per šias eilutes truko **6 461 ms**; tame vaizde yra tik 976 skirtingi `value_key`.

Paruošta nauja, **dar nepritaikyta** [migracija `20261011200000_precompute_effective_size_components.sql`](../../supabase/migrations/20261011200000_precompute_effective_size_components.sql). Ji, nekeičiant materializuotų duomenų, perkelia komponentų išplėtimą, fiksuotas etiketes ir `catalog_effective_size_sort_order` į materializuotą 2 503 skirtingų normalizavimo įėjimų srautą; nuo konkretaus produkto priklausantis etiketės pakaitalas išlieka po sujungimo. Guard tikrina tikslų dabar VPS esantį view fingerprint `3779920dbe0f68902912fb2dca60b6b7`, savininką ir SQL Editor vaidmenį. Nepriklausoma read-only SQL peržiūra materialių semantinių, NULL, dubliuotų komponentų ar schemos defektų nerado. Po vartotojo sėkmingo SQL Editor vykdymo reikia atskirai paleisti [read-only apibrėžimo patikrą](../../supabase/tests/verify_precomputed_effective_size_components_read_only.sql), tada [30 s pilną šaltinio planą](../../supabase/tests/explain_catalog_effective_size_membership_after_component_precompute_read_only.sql). Kol šie rezultatai negauti, cron lieka sustabdytas ir pasivijimas nevykdomas.

## 2026-10-11 18:58–19:04 UTC antro view optimizavimo rezultatas

Vartotojas pateikė migracijos SQL Editor `Success. No rows returned` ir atskirą 18:58:03 UTC read-only patikrą: `cron_active=false`, `view_owner=postgres`, visi keturi komponentų materializavimo požymiai `true`. Codex read-only tuneliu patvirtino naujo view fingerprint `88c25cab7939592911a1f1a045b772e9`. Šį kartą tiek migracijos sėkmė, tiek įdiegimas yra patvirtinti atskirai.

Vartotojo pilnas read-only efektyvių dydžių narystės šaltinio `EXPLAIN ANALYZE` dabar baigėsi per **9 013,227 ms**: į view įėjo 375 751 šaltinio eilutė, skirtingų įėjimų 2 503, išplėstų komponentų 2 658, galutinio view išvestis 381 391, po grupavimo 372 333 eilutės. `unnest` vykdytas tik 2 503 kartus. Taigi anksčiau >30 s trukęs šaltinis patenka į 30 s matavimo ribą. Tai vis dar nėra viso katalogo refresh trukmė.

Prieš kitą pasivijimą Codex read-only 19:04 UTC nustatė, kad ankstesnio nepavykusio 12 min. refresh transakcijos metu atnaujinta pagrindinio MV statistika liko netiksli: `catalog_items_read` `reltuples=175606`, `n_live_tup=175606`, bet tikras `count(*)=104588`; `last_analyze=18:21:41 UTC`, kai senasis refresh dar vyko. 18:33 UTC autovacuum išvalė `n_dead_tup` iki 0, heap tebėra ~1037 MB. `requested_version=2706`, `completed_version=2476`, `last_status=pending`, aktyvaus refresh nėra. Tai rodo, kad prieš kitą pasivijimą reikia naujo `ANALYZE`, atliekamo jau užbaigus nesėkmingą transakciją.

Paruošti nauji SQL Editor failai: [ANALYZE po nepavykusio pasivijimo](../../supabase/manual/20261011_analyze_catalog_items_read_before_optimized_catch_up.sql), tada esama [read-only statistikos patikra](../../supabase/tests/verify_catalog_items_read_analyze_read_only.sql). Tik po jos, kol cron tebėra sustabdytas ir įvertis nuo tikro skaičiaus skiriasi ne daugiau kaip 15%, vienas [kontroliuojamas pasivijimas](../../supabase/manual/20261011_catch_up_catalog_refresh_after_component_optimization_once.sql) su atskira [read-only baigties patikra](../../supabase/tests/verify_catalog_refresh_after_component_optimization_read_only.sql). Failai dar nepritaikyti VPS. SQL Editor upstream timeout vienas pats nereiškia, kad PostgreSQL darbas baigėsi; prieš bet kokį kartojimą tikrinama DB būsena per autorizuotą read-only tunelį.

## 2026-10-11 19:06–19:11 UTC sėkmingas kontroliuojamas pasivijimas

Vartotojas pritaikė naują `ANALYZE`; atskira 19:06:38 UTC read-only patikra rodė `estimated_rows=105685`, `live_rows=104588`, cron sustabdytas ir refresh užrakto nėra. Tai patvirtina statistikos pataisymą po ankstesnės nepavykusios transakcijos.

Vartotojas vieną kartą paleido optimizuoto pasivijimo SQL Editor failą. UI parodė klaidos formato validacijos tekstą, tačiau 19:08:45 UTC read-only patikroje buvo refresh advisory užraktas, `completed_version` tebebuvo 2476. Codex tuneliu nustatė vykdantį PID 1361601 su pagrindinio, facet reikšmių ir dydžių materializuotų vaizdų `ExclusiveLock`; failas **nebuvo kartotas**. 19:10:50 UTC PostgreSQL užbaigė sėkmingai: `last_status=refreshed`, `last_duration_ms=235965`, `refresh_started_at=19:06:54`, `refresh_completed_at=19:10:50`, `completed_version=2707`, `requested_version=2708`, `last_error=NULL`, advisory ir relation refresh užraktų nebeliko. Vienas pasivijimas sumažino atsilikimą nuo 232 iki **1** versijos ir užtruko mažiau nei 5 min.; SQL Editor UI pranešimas nebuvo duomenų bazės klaida. Cron dar sustabdytas.

Read-only lentelių statistika iškart po sėkmės: `catalog_items_read` ~105 778 gyvų, ~93 013 mirusių eilučių, 1037 MB heap ir 5273 MB indeksų; `catalog_item_facet_values_read` ~2 498 157 gyvų, ~39 076 mirusių, 184 MB heap ir 216 MB indeksų; `catalog_size_facets_read` ~372 616 gyvų, ~59 522 mirusių, 41 MB heap. Tai įverčiai po didelio pasivijimo. Autovacuum slenksčiai įdiegti, tačiau jų realų valymą reikia stebėti, kol cron dar sustabdytas, prieš sprendžiant apie nuolatinį 5 min grafiką.

19:14:57 UTC read-only patikra parodė, kad `catalog_items_read` autovacuum baigėsi 19:13:50 UTC ir `n_dead_tup` nukrito iki **0**. Taigi pagrindinio vaizdo valymas po sėkmingo pasivijimo realiai suveikė, kol cron buvo sustabdytas. Kiti du įverčiai (`catalog_item_facet_values_read` ~39 tūkst. ir `catalog_size_facets_read` ~60 tūkst.) liko žemiau jų tuometinių autovacuum slenksčių; dėl jų sėkmės išvados dar nedaromos. Vienas 235,965 s pasivijimas neįrodo, kad kiekvienas įprastas ciklas telpa į 5 min.; reikia stebėti bent du natūralius cron paleidimus ir valymą tarp jų. Paruoštas vienkartinis [incidentui skirtas cron grąžinimo SQL](../../supabase/manual/20261011_resume_catalog_refresh_after_optimized_catch_up.sql) su sėkmingos baigties, užrakto ir autovacuum apsaugomis bei [atskiras read-only stebėsenos SQL](../../supabase/tests/monitor_catalog_refresh_after_resume_read_only.sql). Šie SQL dar nepritaikyti VPS.

Nepriklausoma šių dviejų SQL peržiūra nustatė, kad nauji katalogo pakeitimai po sėkmės gali perjungti `last_status` į `pending`; grąžinimo apsauga dėl to priima `refreshed`, `pending` arba `clean`, bet vis tiek reikalauja patvirtintos versijos, trukmės, laiko, `last_error=NULL`, pasibaigusio autovacuum ir jokio refresh užrakto. Stebėsenos SQL vieną dabartinės būsenos momentinę kopiją pateikia su po 19:14:57 UTC įvykusių cron darbų santrauka. Vien `pg_cron` `succeeded` neįrodo, kad funkcija grąžino `refreshed`; reikia lyginti atskiras momentines kopijas po kiekvieno 5 min intervalo. 19:17:14 UTC read-only būsena tebeatitiko grąžinimo apsaugas; cron dar negrąžintas.

## 2026-10-11 19:20–19:25 UTC chronologinė fazių analizė prieš cron grąžinimą

Vartotojas paprašė prieš cron grąžinimą chronologiškai išanalizuoti visą jo
eigą su `EXPLAIN ANALYZE`. Todėl grąžinimo SQL **nevykdytas**, o išsami
[fazių, tikrųjų šaltinio planų, pasivijimo laiko žymų ir matavimo ribų ataskaita](CRON_REFRESH_CHRONOLOGINE_ANALIZE_2026-10-11.md)
parengta atskirai. Sustabdžius cron po sėkmingo pasivijimo išmatuoti
`catalog_items_read` (10,377 s), `catalog_item_facet_values_read` (13,526 s),
`catalog_size_facets_read` (63,322 s) SELECT šaltiniai, statinių dydžių
talpyklos agregacija (1,539 s) ir šakninių facetų SELECT (3,909 s).
Anksčiau vartotojo pateiktas optimizuoto efektyvių dydžių šaltinio planas
truko 9,013 s. Kiekvieno concurrent refresh rašymo / indeksų palaikymo etapo
atskirai pamatuoti read-only `EXPLAIN ANALYZE` negalima. Tikra viso
pasivijimo trukmė yra 235,965 s, paliekanti apie 64 s iki kito intervalo.

Parengtas **dar nepritaikytas** dydžių klasifikatoriaus literalinės paieškos
SQL kandidatas. Pradinio juodraščio UTF-8 klaida pataisyta; read-only
palyginimas per 104 687 dabartinius produktus davė 0 skirtumų, o izoliuotas
plano laikas sumažėjo nuo 12,306 s iki 2,396 s. Tai nėra viso cron laiko
įrodymas. Cron lieka sustabdytas, kol po galimo pakeitimo bus išmatuotas visas
dydžių šaltinis ir kontroliuojamas refresh; dabartinis vienas sėkmingas
ciklas neleidžia pažadėti, kad kiekvienas būsimas penkių minučių ciklas
baigsis laiku.
