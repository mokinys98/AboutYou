# Katalogo 5 min. cron: chronologinė vykdymo ir planų analizė (2026-10-11)

## Būsena ir matavimo ribos

`catalog-read-model-refresh` VPS **tebėra sustabdytas** (`active=false`). Paskutinis
kontroliuojamas pasivijimas prasidėjo 19:06:54 UTC, baigėsi 19:10:50 UTC ir
truko **235 965 ms**. Jis užbaigė versiją 2707; 19:25 UTC buvo prašoma 2708,
taigi liko vienos versijos skirtumas. 19:25 UTC refresh advisory užrakto nebuvo.
Vienas sėkmingas 236 s ciklas palieka tik apie 64 s iki kito penkių minučių
lizdo ir **neįrodo**, kad visi būsimi ciklai spės laiku.

Visi šiame dokumente naujai surinkti `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)`
planai vykdyti per autorizuotą `codex_reader` tunelį atskirose `BEGIN READ ONLY`
transakcijose, su `statement_timeout` ir `lock_timeout`, užbaigtose `ROLLBACK`.
Matavimai vyko **po** pasivijimo, sustabdžius cron. Tai yra materializuotų vaizdų
šaltinio `SELECT` ir talpyklos skaitymo dalies planai. PostgreSQL
[`EXPLAIN ANALYZE`](https://www.postgresql.org/docs/17/sql-explain.html) tikrai
vykdo nurodytą sakinį; `EXPLAIN ANALYZE SELECT
process_catalog_items_read_refresh()` paleistų duomenis keičiantį refresh.
[`REFRESH MATERIALIZED VIEW`](https://www.postgresql.org/docs/17/sql-refreshmaterializedview.html)
nėra saugus read-only `EXPLAIN` taikinys. Todėl žemiau pateiktų atskirų SELECT
trukmių negalima vadinti tikrosiomis cron fazių trukmėmis ar jų tiesiog sudėti
ir atimti iš 235 965 ms: jos neapima concurrent refresh palyginimo, įrašymo,
indeksų palaikymo, `ANALYZE`, talpyklų mutacijų ir transakcijos pabaigos.

## Tikroji cron eiga ir turimi planai

VPS funkcijų apibrėžimai patikrinti read-only per `pg_get_functiondef`; jų eiga
atitinka [fazių instrumentavimo migraciją](../../supabase/migrations/20261007200200_instrument_catalog_refresh_phase_timings.sql).
Cron komanda nustato `statement_timeout='5min'` ir `lock_timeout='3s'`, tada
kviečia `process_catalog_items_read_refresh()`. Apvalkalas paima transakcijos
advisory užraktą, patikrina `requested_version` ir `completed_version`, o jei
reikia darbo, ta pačia transakcija vykdo žemiau nurodytas fazes eilės tvarka.

| Eilė | Cron fazė / veiksmas | Read-only plano rezultatas | Ko planas neparodo |
| --- | --- | --- | --- |
| 0 | `process_catalog_items_read_refresh()` užraktas ir versijų patikra | Būsenos ir užrakto snapshot, be atskiro `EXPLAIN ANALYZE` | `busy` / `clean` kelio ir rašomos būsenos kainos |
| 1 | `REFRESH MATERIALIZED VIEW CONCURRENTLY catalog_items_read` | [Šaltinio planas](20261011_catalog_items_read_post_catchup_source_plan.json): **10 376,937 ms**, 104 687 eilutės, 39 366 shared read blokai, 17 321 temp write blokas | Concurrent diff, DELETE/INSERT, 5,27 GB indeksų priežiūra |
| 2 | `ANALYZE catalog_items_read` | Negalima vykdyti read-only; `last_analyze=19:08:12 UTC` | Tiksli `ANALYZE` trukmė |
| 3 | `REFRESH ... CONCURRENTLY catalog_item_facet_values_read` | [Šaltinio planas](20261011_catalog_item_facet_values_read_post_catchup_source_plan.json): **13 525,581 ms**, 2 445 296 eilutės, 132 755 shared read, 15 627 temp write blokai | Diff, įrašymas ir indeksų priežiūra |
| 4 | `REFRESH ... CONCURRENTLY catalog_size_facets_read` | [Šaltinio planas](20261011_catalog_size_facets_read_post_catchup_source_plan.json): **63 322,446 ms**, 372 616 eilučių, 280 713 shared read, 14 052 temp write blokai | Diff, įrašymas, indeksai; tai brangiausias tiesiogiai išmatuotas šaltinis |
| 5 | `ANALYZE catalog_size_facets_read` | Negalima vykdyti read-only; `last_analyze=19:10:32 UTC` | Tiksli `ANALYZE` trukmė |
| 6 | `invalidate_catalog_facets_cache()` → `REFRESH ... CONCURRENTLY catalog_effective_size_membership_read` | [Vartotojo SQL Editor šaltinio planas](20261011_catalog_effective_size_membership_source_plan_from_sql_editor.md): **9 013,227 ms**, 381 391 view eilutė, 372 333 grupės; išmatuota prieš pasivijimą po optimizavimo | Concurrent diff ir indeksų palaikymas; planas yra kito laiko snapshot |
| 7 | `catalog_static_size_facets_cache` agregacija ir UPSERT | [Agregacijos SELECT planas](20261011_catalog_static_size_facets_cache_select_plan.json): **1 539,059 ms**, 1 JSON rezultatas | UPSERT ir jo užraktai |
| 8 | `DELETE FROM catalog_facets_cache` | Lentelėje buvo 1 eilutė; tikro DELETE read-only `EXPLAIN ANALYZE` nevykdėme | DELETE trukmė ir WAL |
| 9 | `catalog_facets_cached('{}')` šakninės talpyklos paruošimas | [Įeinančio `catalog_root_facets()` SELECT planas](20261011_catalog_root_facets_select_plan.json): **3 908,845 ms**, 1 JSON rezultatas | Dydžių talpyklos skaitymas, įdėjimas / UPSERT ir transakcijos pabaiga |

Fazių 1–5 vykdymo tvarka yra `rebuild_catalog_items_read_internal()` viduje;
6–9 yra jo kviečiamos `invalidate_catalog_facets_cache()` viduje. Sėkmės
atveju apvalkalas tik tada įrašo `completed_version` ir `last_duration_ms`.
Funkcija klaidą sugauna ir grąžina JSON su `failed`; todėl vien
`pg_cron` įrašas `succeeded` nėra pilno refresh sėkmės įrodymas.

## Ką rodo viso pasivijimo chronologija

`refresh_started_at=19:06:54,125720`, `catalog_items_read.last_analyze=
19:08:12,124852`, `catalog_size_facets_read.last_analyze=19:10:32,463156`,
`refresh_completed_at=19:10:50,091620` UTC. Šie statistikos laukai leidžia
apytikriai lokalizuoti viso darbo eigą: iki pagrindinio `ANALYZE` žymos praėjo
~78 s; nuo jos iki dydžių `ANALYZE` žymos ~140 s; po jos iki baigties ~18 s.
Tai **ne atskirų fazių chronometras**: statistikos žymos nėra mūsų programinės
fazės pradžios / pabaigos įrašai.

Ankstesnis 18:16 UTC pasivijimas baigėsi tik po 720 439 ms, nes
`effective_size_membership` fazė pasiekė 260 626 ms timeout, o prieš ją
buvo praėję maždaug 459 s. Po dviejų efektyvių dydžių view optimizacijų tas
pats šaltinio SELECT vartotojo SQL Editor plane užtruko 9,013 s, o po to visas
vienkartinis pasivijimas sėkmingai baigėsi per 235,965 s. Šis priežastinis
ryšys tikėtinas, bet skirtingų paleidimų duomenys nesuteikia tiksliai
apskaičiuoto vienos fazės pagreitėjimo.

Dydžių šaltinio plano viršuje `Append` išvedė 373 108 eilutes per ~43,3 s;
variantų šaka (321 711 eil.) užtruko ~35,4 s, legacy šaka (51 397 eil.)
~7,8 s. Po jų sekantis `Result` su dydžių reikšmių išvedimu pasiekė ~62,0 s,
o `Sort/Unique` 372 616 eilučių užbaigė iki ~63,0 s. `catalog_size_domain()`
klasifikatorius kviečiamas kiekvienai variantų / legacy įvesties eilutei.
Izoliuotas senos funkcijos `EXPLAIN ANALYZE` per visas 104 687 dabartines
`catalog_items_read` eilutes truko [12 305,866 ms](20261011_catalog_size_domain_installed_comparison_plan.json).

## Patikrintas kandidatas dydžių fazei

Paruoštame [klasifikatoriaus pakeitimo SQL](../../supabase/migrations/20261011210000_optimize_catalog_size_domain_predicates.sql)
esami vien tik literaliniai regex fragmentai keičiami `position()` paieška.
Pirmo juodraščio klaidingai užkoduotos lietuviškos raidės buvo pataisytos
**prieš bet kokį VPS vykdymą**. [Read-only semantikos palyginimas](../../supabase/tests/verify_catalog_size_domain_predicate_equivalence_read_only.sql)
patikrino visus **104 687** dabartinius produktus: **0 neatitikimų**. Su tuo
pačiu įvesties rinkiniu siūlomos išraiškos
[`EXPLAIN ANALYZE`](20261011_catalog_size_domain_literal_candidate_plan.json)
truko **2 396,240 ms**, dabartinės funkcijos – 12 305,866 ms. Tai tik
izoliuotas klasifikatoriaus palyginimas; viso `catalog_size_facets_read`
SELECT ir concurrent refresh po migracijos trukmė nežinoma.

Migracija **VPS dar nepritaikyta**. Ji nekeičia cron aktyvumo ir nevykdo
refresh; prieš pakeitimą tikrina tikslų VPS funkcijos apibrėžimo fingerprint
`126e94ff3bb480bead8470768d63795a` ir savininką. Jei bus taikoma SQL
Editor, atskira [read-only diegimo patikra](../../supabase/tests/verify_catalog_size_domain_predicates_read_only.sql)
turi rodyti vieną eilutę: `cron_active=false`, `function_owner=postgres`,
`uses_literal_checks=true`, `old_regex_checks_absent=true`. Tada reikia vėl
vykdyti ir [visų dabartinių produktų palyginimą](../../supabase/tests/verify_catalog_size_domain_predicate_equivalence_read_only.sql):
`compared_rows > 0`, `mismatched_rows = 0`. Apibrėžimo požymių patikra viena
neįrodo viso funkcijos turinio; šis palyginimas tikrina dabartinius duomenis.
Toliau reikia vėl pamatuoti visą dydžių šaltinį ir vieną kontroliuojamą
refresh, prieš svarstant
5 min. cron grąžinimą. Dabartiniai 235,965 s nėra pakankama garantija.

## DB augimas ir trūkstamas įrodymas

`catalog_items_read` po sėkmingo pasivijimo turėjo apie 93 tūkst. mirusių
eilučių; kol cron buvo sustabdytas, 19:13:50 UTC autovacuum jas išvalė ir
`n_dead_tup` sumažėjo iki 0. Tačiau fizinis heap tebėra apie 1 037 MB, indeksai
apie 5 273 MB: įprastas VACUUM pakartotiniam naudojimui atlaisvina vietą
lentelės viduje, bet nebūtinai sumažina failų dydį. Su nepertraukiamais
concurrent refresh bandymais autovacuum gali negauti tinkamo lango; nauji
500 + 2% slenksčiai padeda tik kai valymas gali įvykti tarp darbų.

Tikri `catalog_refresh_phase` `RAISE LOG` įrašai iš šio pasivijimo nebuvo
gauti per `docker logs`; todėl **tikslių visų fazių laikų neturime**. Juos
ateityje galima gauti tik iš veikiančios fazių telemetrijos arba papildomos
instrumentavimo migracijos ir naujo kontroliuojamo paleidimo. Dabartinės
read-only užklausos nesuteikia pagrindo žadėti, kad penkių minučių cron
„visada“ praeis be backlog. Toks teiginys reikalauja pakartotinių natūralių
ciklų trukmių, kiekvieno `completed_version` pokyčio ir `n_dead_tup` /
autovacuum stebėjimo. Iki tol cron lieka sustabdytas.
