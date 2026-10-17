# Katalogo 5 min. cron: chronologinė vykdymo ir planų analizė (2026-10-11)

## Būsena ir matavimo ribos

`catalog-read-model-refresh` VPS **tebėra sustabdytas** (`active=false`). Paskutinis
kontroliuojamas pasivijimas prasidėjo 19:06:54 UTC, baigėsi 19:10:50 UTC ir
truko **235 965 ms**. Jis užbaigė versiją 2707; 19:25 UTC buvo prašoma 2708,
taigi liko vienos versijos skirtumas. 19:25 UTC refresh advisory užrakto nebuvo.
Vienas sėkmingas 236 s ciklas palieka tik apie 64 s iki kito penkių minučių
lizdo ir **neįrodo**, kad visi būsimi ciklai spės laiku.


### Ankstesni natūralūs ciklai (2026-10-05)

[API refresh probe žurnale](API_REFRESH_PROBE_2026-10-05.jsonl) užfiksuoti du
sėkmingi natūralūs ciklai: 2115 versijos ciklas 09:10-09:14:04 UTC truko
244 797 ms (4 min. 4,8 s), o 2116 versijos ciklas 09:55-09:59:24 UTC truko
264 465 ms (4 min. 24,5 s). Antras ciklas iki 5 min. intervalo paliko tik
35,5 s. Spalio 11 d. 235 965 ms ciklas paliko apie 64 s. Visi trys sėkmingi
matuojami pilni ciklai artėjo prie 5 min. ribos, todėl vienas sėkmingas paleidimas
nėra stabilaus grafiko garantija. Fazių laikai spalio 5 d. probe faile nebuvo
atskirai užfiksuoti.

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

2026-10-11 ataskaitos užfiksavimo metu migracija **VPS dar nebuvo pritaikyta**.
Ji nekeičia cron aktyvumo ir nevykdo refresh; prieš pakeitimą tikrina tikslų VPS funkcijos apibrėžimo fingerprint
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

## 2026-10-14 read-only patikra po klasifikatoriaus migracijos

Vartotojas pranešė, kad klasifikatoriaus migraciją pritaikė, bet SQL Editor
patikrų dar nevykdė. Per autorizuotą read-only tunelį patvirtintas pakeistas
funkcijos fingerprint `5f1b4d6e0b1bfa2a534ae7080930e312`, savininkas `postgres`,
visos aštuonios lietuviškos / ASCII literalinės predikatų grupės ir senų regex
šakų nebuvimas. Įdiegtos funkcijos ir atskiros naujų literalinių taisyklių
versijos palyginimas baigėsi: **104 687 įvesties eilutės, 0 neatitikimų**.

14 d. read-only būsenos snapshot: `requested_version=2974`,
`completed_version=2707`, `last_status=pending`, paskutinis sėkmingas refresh
dar 2026-10-11 19:10:50 UTC. Tuo momentu refresh užraktų nebuvo. `codex_reader`
neturi `cron` schemos `USAGE`, todėl šiuo tuneliu **negalima patvirtinti, ar
cron aktyvus**. Prieš vykdant brangų viso dydžių šaltinio planą, vartotojas
turi paleisti `supabase/tests/verify_catalog_refresh_current_state_read_only.sql`.

Lentelių statistikos snapshot: `catalog_items_read` `n_dead_tup=0`, heap ~1,01
GiB, indeksai ~5,15 GiB; `catalog_item_facet_values_read` 39 076 dead tuple;
`catalog_size_facets_read` 59 522 dead tuple. Pastarieji skaitikliai yra
statistiniai įverčiai, o ne tikslus `count(*)`. Cron aktyvumas ir naujausias
autovacuum / refresh langas dar nepatvirtinti; kol nėra tylaus lango, pilno
dydžių šaltinio `EXPLAIN ANALYZE` neatliekamas.

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


## 2026-10-14 po migracijos: aktualūs šaltinių planai

Vartotojo SQL Editor read-only būsenos rezultatas 19:36:59 UTC patvirtino
cron_active=false, refresh_run_running=false, refresh_lock_now=false;
requested_version=2974, completed_version=2707, tarpas 267.
Codex pakartotinai patikrino užraktus tuneliu prieš ir po planų; abiem
atvejais jų buvo 0.

Po migracijos aktualūs view šaltinių EXPLAIN ANALYZE rezultatai:

- [catalog_items_read](20261014_catalog_items_read_source_plan.json): **8 196,747 ms**, 104 834 eilutės.
- [catalog_item_facet_values_read](20261014_catalog_item_facet_values_read_source_plan.json): **8 756,074 ms**, 2 445 296 eilučių.
- [catalog_size_facets_read](20261014_catalog_size_facets_read_after_domain_optimization_plan.json): **72 463,683 ms**, 369 784 eilutės.
- catalog_effective_size_membership_read planas per Codex tunelį nepaleistas: codex_reader neturi EXECUTE teisės catalog_strip_known_size_description. Vartotojui paruoštas [SQL Editor EXPLAIN ANALYZE](../../supabase/tests/explain_catalog_effective_size_membership_after_component_precompute_read_only.sql); ankstesnis vartotojo planas po komponentų optimizavimo truko 9 013,227 ms.

Dydžių pilno šaltinio planas užtruko 72,464 s, t. y. 9,141 s ilgiau už
spalio 11 d. 63,322 s matavimą. Tai neįrodo, kad migracija sulėtino visą
užklausą: pasikeitė duomenų šakų dydžiai (variantų šaka išvedė
343 317 vietoj 321 711 eilučių; legacy šaka – 27 015 vietoj 51 397), o
planų fizinių skaitymų kiekis liko panašus (~282 tūkst. shared read blokų).
Izoliuota funkcijos išraiška buvo greitesnė, bet pilno view SELECT
pagerėjimo šie du skirtingų snapshot planai nepatvirtina.

Po matavimų 19:39:18 UTC būsena liko 2974/2707 pending, refresh užraktų 0.
Pagrindinio vaizdo dead tuple įvertis 0, facet vaizdo 39 076, dydžių vaizdo
59 522; pastarieji autovacuum laikai vis dar spalio 11 d. Visas cron pasivijimas
po spalio 14 d. migracijos dar neatliktas. 5 min. cron negrąžintas.

## 2026-10-14 klasifikatoriaus vietos eksperimento rezultatai

Po pilno view plano papildomai palyginti trys read-only EXPLAIN ANALYZE
variantai tame pa?iame dabartiniame katalogo snapshot:

- ?diegta catalog_size_domain() per 104 834 catalog_items_read produktus:
  [22 697,726 ms](20261014_catalog_size_domain_installed_after_migration_plan.json).
- Tokia pati nauj? position() taisykli? i?rai?ka ?terpta tiesiai ? SELECT ir
  vertinama vien? kart? kiekvienam produktui:
  [1 496,088 ms](20261014_catalog_size_domain_literal_expression_plan.json).
- Tiesiogin? i?rai?ka suskai?iuota vien? kart? vienam produktui ir sujungta su
  pasirinktin? product_size_options eilut?mis:
  [1 875,922 ms](20261014_catalog_size_domain_precompute_option_branch_plan.json);
  sujungimas pateik? 343 317 variant? eilu?i?.

Tai rodo didel? SQL funkcijos kvietimo / skai?iavimo vietos kain?: position()
i?rai?ka pati greita, ta?iau pakeitus regex funkcijos viduje pilno ?altinio
laikas netapo trumpesnis. Dabartinio MV apibr??ime klasifikavimo funkcija
kvie?iama kiekvienai produkto dyd?io parink?iai. Vieno domeno skai?iavimo
vienam produktui bandomasis planas smarkiai suma?ina tik variant? ?akos
klasifikavimo darb?. Bandymas dar neapima legacy ?akos, reik?mi? normalizavimo,
DISTINCT / Unique, indeks? ar viso MV refresh; jo 1,876 s negalima laikyti
viso catalog_size_facets_read trukm?s prognoze.

Kitas saugus optimizavimo kandidatas tur?t? pirmiau i?matuoti piln? read-only
SELECT su item_domains AS MATERIALIZED vienam produkto ID, tada sujungti ir
variant?, ir legacy ?akas su tais domenais. B?tina palyginti visus senos ir
naujos u?klausos rezultatus. Materializuoto vaizdo saugomos u?klausos
pakeitimui reikia atskiro dependency / grant / unique-index atk?rimo plano;
?ios analiz?s metu VPS DDL nevykdytas, materializuoti vaizdai nebuvo perkurti,
refresh nebuvo paleistas.



## 2026-10-14 19:36-19:59 UTC: per produkto išankstinis domeno skaičiavimas

Vartotojo 19:36:59 UTC SQL Editor rezultatas: cron `active=false`, vykdomo
job nėra, refresh lock nėra; `requested_version=2974`, `completed_version=2707`,
tarpas 267, paskutinė baigta versija ir sėkmingas refresh liko 2026-10-11.
Read-only tunelio vaidmuo neturi `cron` schemos `USAGE`, todėl cron būseną
patvirtina vartotojo rezultatas; VPS DDL ar refresh Codex nevykdė.

Naujas kandidatas `item_inputs AS MATERIALIZED` vieną kartą produktui apskaičiuoja
domeną ir tą pačią reikšmę naudoja variantų bei legacy dydžių šakose.
Palyginimai tame pačiame šaltinių snapshot:

- Kandidatas su įdiegtos `catalog_size_domain()` funkcijos kvietimu: 36,637 s,
  369 784 eilutės ([JSON planas](20261014_catalog_size_facets_read_per_product_domain_plan.json)).
- Dabartinė view šaltinio užklausa prieš tokį kandidatą, tikrinant abiejų krypčių
  `EXCEPT ALL`: 114,981 s; abi versijos grąžino 369 784 eilutes, skirtumų 0.
- Inline literalus `CASE` su `position()` išraiškomis, domeną taip pat
  apskaičiuojant vieną kartą produktui: 19,656 s, 369 784 eilutės
  ([JSON planas](20261014_catalog_size_facets_read_inline_domain_plan.json)).
  Prieš planą įdiegtos funkcijos ir tų pačių literalinių taisyklių palyginimas
  apėmė 104 687 produktus, truko 23,459 s ir rado 0 klasifikavimo neatitikimų.

Svarbi skirtis: kandidato 369 784 eilutės skiriasi nuo dabar saugomo
`catalog_size_facets_read` MV turinio (372 616): `EXCEPT ALL` rado 7 340 tik
kandidate ir 10 172 tik sename MV. Dabartinio šaltinio SELECT palyginimas su
esama užklausa skirtumų nerado, todėl materializuotas rezultatas neatitinka
dabartinių šaltinių snapshot; tikėtina, kad priklausomi įvesties duomenys
pasikeitė po jo sukūrimo. Šių skaičių negalima laikyti kandidato klaida ar
naudoti kaip lygybės patikros su tuo pačiu snapshot pakaitalo.

Šaltinio eilutės viršutinis mazgas buvo `Unique` / `Sort`; `Append` grąžino
370 332 tarpines eilutes, iš kurių 343 317 variantų ir 27 015 legacy šakos.
Inline kandidato `EXPLAIN ANALYZE` truko 19,656 s. Pilno šaltinio trukmė taip
sumažėjo nuo ankstesnio 72,464 s matavimo iki 19,656 s (apie 3,7 karto
šiame matavime), bet tai nėra `REFRESH MATERIALIZED VIEW` trukmė: planas
neapima heap / index rašymo, kitų refresh fazių ir viso cron job. Todėl
5 min. ciklo sėkmė dar neįrodyta.

MV užima apie 41 MB heap ir 95 MB indeksų. Tiesioginė priklausomybė yra
`catalog_size_facets_read_effective` paprastas view. Galimas pakeitimas turi
saugoti seną MV, atkurti tris indeksus ir `service_role` SELECT grant, perkelti
paprastą view priklausomybę į naują objektą ir tik po to atnaujinti žemiau
esančią narystės MV. Kol kas stage MV, indeksas, view ar cron nuotoliniu būdu
nebuvo pakeisti.


### Kitas saugus etapas (dar nepritaikytas VPS)

Paruoštas [stage materialized view kūrimo SQL](../../supabase/migrations/20261014195500_stage_optimized_catalog_size_facets_read.sql)
kuria tik tuščią shadow MV su išmatuotu SELECT; jis neatnaujina cron ar vartotojų
skaitomų view. Po sėkmingo kūrimo atskiras
[vienkartinis pildymo skriptas](../../supabase/manual/20261014_populate_optimized_catalog_size_facets_stage_once.sql)
atlieka vieną paprastą stage `REFRESH`. Jo laikas dar neišmatuotas; SQL Editor
upstream timeout atveju pirmiausia tikrinti
[stage būseną](../../supabase/tests/verify_optimized_catalog_size_facets_stage_read_only.sql),
o ne kartoti refresh. Tada
[abipusis read-only sulyginimas](../../supabase/tests/verify_optimized_catalog_size_facets_stage_equivalence_read_only.sql)
turi rodyti `differing_rows=0`. Tik gavus tą rezultatą rengiamas atskiras
indeksų / grantų ir priklausomybių perjungimo etapas. Cron iki atskiro
kontroliuojamo viso ciklo patvirtinimo negrąžinamas.


2026-10-14 20:01:10 UTC tunelio read-only būsena: `requested_version=2975`,
`completed_version=2707`, tarpas 268, `last_status=pending`, refresh lockų 0.
Palyginti su 19:36:59 būsena, nauja versija atsirado analizės metu, kai refresh
nevyko. Tai didina neapdorotų pokyčių versijų tarpą, bet nereiškia 268 atskirų
cron job: funkcija užfiksuoja vieną `target_version` paleidimo pradžioje ir jį
pažymi baigtu; pokyčiai, atsiradę per ciklą, lieka kitam ciklui.

## 2026-10-17 stage u?pildymas ir lygyb?s patikra

Vartotojo SQL Editor rezultatai 16:56:32 ir 16:58:01 UTC patvirtino, kad
`catalog-read-model-refresh` cron teb?ra sustabdytas. Stage materialized view
sukurtas `postgres` savininko ir apibr??ime naudoja `item_inputs AS MATERIALIZED`.
Pirmoje patikroje jis buvo tu??ias (`relispopulated=false`, 0 bytes); v?lesn?je
jau u?pildytas (`relispopulated=true`, `reltuples=367831`, heap 35 MB).

Pataisyta read-only stage b?senos patikra: PostgreSQL planuodamas u?klaus?
patikrino tiesiogin? nuorod? ? neu?pildyt? MV net ir `CASE` ?akoje, tod?l senas
`stage_rows` skai?iavimas k?l? klaid?. Tikslus eilu?i? skai?ius dabar atskirtas
? atskir? patikr?, kuri vykdoma tik po `stage_populated=true`.

Po u?pildymo Codex read-only tuneliu gavo stage tiksl? skai?i? 367831. Pirmas
?altinio ir stage sulyginimas: ?altinis 367828 eilu?i?, stage 367831, i? viso
7 skirtumai (2 tik ?altinyje, 5 tik stage). Pakartotinis vienos SQL u?klausos
snapshot sulyginimas netrukus parod? 367824 ?altinio eilu?i?, 367831 stage
ir 39 skirtumus (16 tik ?altinyje, 23 tik stage). `requested_version` per
read-only matavimus pakito i? 3223 ? 3224, `completed_version=2707`, b?sena
`pending`; paskutinis s?kmingas pilnas refresh teb?ra spalio 11 d. 19:10:50 UTC.
Refresh u?rakto tuo metu ???vo n?ra.

Skirtum? prie?astis kol kas nenustatyta: tarp stage u?pildymo ir patikros
?altinis gal?jo pasikeisti, ta?iau vien `requested_version` augimas to
ne?rodo. Vieno statement snapshot palyginime stage ir dabartinis ?altinis
vis tiek skyr?si, tod?l stage dar negalima perjungti ? production view.
Cron ne?jungtas, stage neprijungtas prie vartotoj? view ir lygyb?
nepatvirtinta. Toliau reikia stabilaus ?altinio snapshot arba saugaus
stage u?pildymo ir lygyb?s patikros vienos transakcijos plane. ?is bandymas
vis dar nepatvirtina viso 5 minu?i? cron ciklo trukm?s.

Papildomas read-only patikrinimas 17:01 UTC nustat?, kad `product_size_options`
turi `fetched_at` lauk?, o pavyzdini? nesutampan?i? produkt? dyd?i? ?ra?ai buvo
atnaujinti 16:58:52?17:00:14 UTC, t. y. po vartotojo 16:58:01 UTC patvirtinto
stage u?pildymo. Pavyzd?iui, dir?? produktui stage tur?jo dyd?ius 100, o
naujesn?s `product_size_options` eilut?s jau pateik? 90, 95 ir 100. Tai
patvirtina, kad bent dalis skirtum? atsirado d?l ?altinio pakeitim? po stage
suk?rimo; vis? 39 skirtum? prie?astis ir kandidato pilna lygyb? dar n?ra
patvirtintos.

Parengtas, bet nevykdytas [vienos repeatable-read transakcijos stage atnaujinimo
ir lygyb?s SQL](../../supabase/manual/20261017_refresh_and_verify_optimized_catalog_size_facets_stage_once.sql).
Jis apsauginiais patikrinimais reikalauja sustabdyto cron, atnaujina tik shadow
stage MV ir tame pa?iame duomen? snapshot pateikia tikslius abiej? kryp?i?
skirtumus. Jei `differing_rows` ne 0, production priklausomyb?s nekei?iamos.
SQL Editor upstream timeout atveju prie? kartojim? tikrinama stage b?sena.

## 2026-10-17 17:06 UTC: stage source sulygintas viename snapshot

Vartotojo paleistas `20261017_refresh_and_verify_optimized_catalog_size_facets_stage_once.sql`
s?kmingai atnaujino tik shadow stage ir tame pa?iame `REPEATABLE READ`
snapshot palygino su source: `requested_version=3224`, `completed_version=2707`,
`source_rows=367826`, `stage_rows=367826`, `differing_rows=0`. Tai patvirtina
kandidato lygyb? ?ioje transakcijoje, bet dar ne viso cron ciklo laik? ar
produkcin? perjungim?.

Read-only ACL patikra parod?, kad dabartinis stage turi `SELECT` teises
`anon` ir `authenticated` rol?ms (taip pat `service_role`), o senasis
`catalog_size_facets_read` leid?ia SELECT tik `service_role` ir savininkui.
Paruo?ta atskira teis? susiaurinimo migracija ir jos read-only patikra;
nuotoliniu b?du jos dar netaikiau.

Cron fazi? kontekstas lieka svarbus: 2026-10-11 kontroliuojamas refresh anks?iau
baig?si `effective_size_membership` faz?s statement timeout po ~260,6 s.
V?lesnis ?ios faz?s `EXPLAIN ANALYZE` po komponent? i?ankstinio skai?iavimo
SQL Editor?yje taip pat buvo upstream timeout ties 30 s. Naujas stage dyd?i?
?altinis ?ios brangios faz?s nepa?alina. Paruo?tas
[read-only EXPLAIN pagal stage source](../../supabase/tests/explain_catalog_effective_size_membership_from_optimized_stage_read_only.sql),
kuris naudoja dabartin? VPS `catalog_size_facets_read_effective` view
apibr??t?, bet joje ?altin? nukreipia ? optimizuot? stage. J? reikia i?matuoti
prie? perjungimo migracijos rengim?. Visas cron teb?ra sustabdytas pagal
vartotojo SQL Editor rezultat?; s?kmingas 5 min. ciklas dar ne?rodytas.

Dabartinis produkcinis `catalog_size_facets_read` u?ima 135 MB i? viso:
41 MB heap ir 39/29/26 MB trys indeksai. Stage u?ima 35 MB heap ir dar neturi
indeks?. Per laikin? rollback lang? indeks? atk?rimas padidins DB u?imam? viet?;
po patvirtinto perjungimo sen? MV reik?t? pa?alinti tik atskiru, patikrintu
sprendimu. Stage ir production dar neperjungti.

## 2026-10-17 17:35?17:53 UTC: stage ACL ir planas

Vartotojo read-only SQL Editor patikra 17:35:22 patvirtino, kad optimizuotas
stage yra u?pildytas materialized view, `anon`, `authenticated` ir `PUBLIC`
neturi `SELECT`, o `service_role` turi. Tai patvirtina, kad
`20261017171000_lock_down_optimized_catalog_size_stage.sql` pritaikyta.
Stage teb?ra diagnostinis objektas; jis dar nepakeit? production
`catalog_size_facets_read`.

Vartotojo `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` pilnam naryst?s SELECT,
naudojant stage ir VPS esam? effective-size normalizavimo apibr??t?, gr??ino
374 337 tarpini? eilu?i? ir sugrupavo ? 364 804 eilutes per 7 927 ms. Stage
nuskaitymas su override sujungimu u?truko apie 384 ms; normalizavimo,
komponent? apdorojimo ir grupavimo dalis sudar? likusi? laiko dal?. Atlikti
sort'ai naudojo disk? (apie 29 824 kB ir 26 744 kB), EXPLAIN nurod? 9 631
bloko temp read ir 9 650 temp written. Tod?l kritin? SELECT dalis, anks?iau
u?trukusi apie 260,6 s ir at?aukta, su stage ?altiniu dabar i?matuota ~7,9 s.
Tai stiprus ?rodymas, kad ?altinio planas pagreit?jo, bet ne faktinio
`REFRESH MATERIALIZED VIEW CONCURRENTLY` laikas ir ne visas cron ciklas.

Codex authorized read-only tuneliu 17:53:02 UTC patikrino b?sen?:
`requested_version=3229`, `completed_version=2707`, `last_status=pending`,
versij? tarpas 522. Paskutinis u?fiksuotas pilnas s?kmingas refresh vis dar
2026-10-11 19:10:50 UTC, trukm? 235 965 ms. Stage turi 367 826 eilu?i? ir 35
MB heap, bet neturi indeks?; senas production dyd?i? MV turi 372 616 eilu?i?,
41 MB heap ir tris valid?ius/ready indeksus, kartu 94 MB. `effective` view
priklausomyb? teb?ra susieta su senu MV. Stage perjungimas reikalaut? unique
indekso `CONCURRENTLY` refresh'ui, priklausomyb?s perri?imo ir rollback plano;
kol kas niekas i? to remote nebuvo vykdyta.

Kadangi tarp 17:06 lygyb?s patikros ir dabar pra?jo laiko, o `requested_version`
pakilo iki 3229, prie? bet kok? swap reikia dar kart? atnaujinti stage ir
patvirtinti `differing_rows=0` viename snapshot. Tada galima ?diegti
suderinamus indeksus ir atlikti vien? kontroliuojam? viso refresh bandym?,
cron paliekant sustabdyt?; tik jo s?km?, trukm? <300 000 ms ir versij?
atsilikimo/heap b?kl?s patikra leis svarstyti cron gr??inim?. ?iuo momentu
penki? minu?i? garantija dar ne?rodyta.

Toliau paruo?tas atskiras, tik shadow stage lie?iantis indeks? ?ingsnis:
`20261017180000_index_optimized_catalog_size_stage.sql`. 17:53 read-only
patikra stage'e rado 367 826 eilutes, visas su unikaliu `(product_id, token)`
raktu (0 dublikat?), tod?l galima kurti `REFRESH ... CONCURRENTLY` b?tin?
unikal? indeks? ir production formato domain/token indeksus. Migracija turi
s?lygas d?l sustabdyto cron, neu?imto refresh, stage savininko/popoliuotumo ir
rakt? unikalumo; ji nekei?ia production view ar cron. Prie? j? taikant reikia
pakartoti vieno snapshot stage refresh/lygyb?s fail?, nes source versija po
17:06 padid?jo. Po migracijos atskiras read-only patikrinimas turi patvirtinti
indeks? valid/ready b?sen? ir ACL; ?is migracijos ?ingsnis kol kas nepatvirtintas
kaip pritaikytas.


## 2026-10-17 18:37 UTC: po SQL Editor kliento klaidos patikrinta read-only

Vartotojo ekrane po stage refresh/lygyb?s failo rodytas `invalid_type` JSON
n?ra PostgreSQL klaidos teksto, tod?l vien UI vaizdas nepatvirtino ar atmet?
transakcijos pabaig?. Nekartojant jokio write veiksmo, Codex per autorizuot?
read-only tunel? 18:37:30 UTC tame pa?iame SELECT snapshot palygino dabartin?
source su stage: source 367783, stage 367783, `differing_rows=0`, abiej? kryp?i?
skirtumai 0. Stage `reltuples` taip pat buvo 367783; ankstesn? read-only
b?sena rod? 367826. Tai patvirtina dabartin? stage duomen? lygyb?, bet ne SQL
Editor kliento vykdymo patvirtinim? ar cron b?sen?. `requested_version=3230`,
`completed_version=2707`, `pending`.

Atsi?velgiant ? nulinius skirtumus, stage indeks? shadow migracija gali b?ti
kitas saugus ?ingsnis: ji pati dar kart? SQL Editor pus?je patikrins, kad cron
sustabdytas ir refresh lock n?ra, prie? liesdama tik stage indeksus.


## 2026-10-17 19:13 UTC: indexed stage ir v?l pasikeit?s source

Vartotojo read-only indeks? i?ra?as patvirtino tris stage indeksus: visi
`indisvalid=true`, `indisready=true`; unikalus `(product_id, token)` indeksas
18 MB, domeno indeksas 20 MB, token indeksas 19 MB. Tunelio read-only patikra
19:13 UTC patvirtino stage `relispopulated=true`, heap 35 MB, i? viso su
indeksais 92 MB. Bendra laikina kopijos vieta ?alia senos 135 MB production
lentel?s yra apie 92 MB; sen? MV pa?alinus po s?kmingo perjungimo, skirtumas
b?t? apie 43 MB ma?iau nei dabar.

Tame pa?iame read-only snapshot stage jau buvo atsilik?s nuo source:
source 367750 eilu?i?, stage 367783, `differing_rows=233` (100 tik source,
133 tik stage), `requested_version=3234`, `completed_version=2707`.
Tod?l stage negalima perjungti ar laikyti patvirtintu production kandidatu.
Paruo?tas preflight ir vieno `REFRESH MATERIALIZED VIEW CONCURRENTLY` failai;
tai pamatuos stage refresh'? su indeksais ir atnaujins tik izoliuot? stage.
Po jo Codex patikrins source-stage lygyb? read-only tuneliu. Pilnas cron ciklas
vis tiek liks atskirai nepatvirtintas.


## 2026-10-17 19:38?19:40 UTC: indexed stage atnaujintas ir patikrintas

Vartotojas SQL Editor patvirtino preflight: cron sustabdytas, aktyvaus run ir
refresh lock n?ra, stage u?pildytas, `postgres` savininkas, visi indeksai valid?s.
Tada vieno sakinio `REFRESH MATERIALIZED VIEW CONCURRENTLY` stage komandai
SQL Editor gr??ino `Success`. Codex read-only tuneliu 19:40 UTC patvirtino, kad
stage po atnaujinimo sutampa su source viename snapshot: 367750 eilu?i? abiejose
pus?se, 0 skirtum?; pats read-only palyginimas truko 22,036 s. Stage dabar
u?ima 92 MB su indeksais, `n_dead_tup` ?vertis buvo 133. Vartotojas nepateik?
refresh trukm?s, tod?l kandidatinio concurrent refresh faz?s ms laikas lieka
ne?inomas. `requested_version=3236`, `completed_version=2707`, `pending`.

Read-only patikra parod?, kad dabartin? `catalog_size_facets_read_effective`
view vis dar remiasi senu MV; jos savininkas `postgres`, o `service_role` turi
SELECT. Parengtas guarded transakcinis production perjungimas su tiksliu source
ir stage sulyginimu tame pa?iame `REPEATABLE READ` snapshot, senu MV i?saugotu
kaip u?rakintu backup, ir atskira read-only cutover patikra. Atskirai parengtas
rollback SQL, kuris atstato sen? MV ir view priklausomyb?; po rollback vis tiek
reik?t? naujo s?kmingo read-model refresh, kad priklausomas membership/cache
modelis b?t? suvienodintas. Nei cutover, nei rollback, nei cron pakeitimas
nuotoliniu b?du nebuvo atliktas.

## 2026-10-17 19:59 UTC: cutover SQL klaida ir read-only busenos patikra

Vartotojo paleista cutover migracija grazino PostgreSQL klaida `42P01: relation "stage_rows" does not exist`. Klaida yra paruosto SQL trukumas: lyginimo CTE naudojo `stage_rows`, bet jo neapibreze. Migracijos failas pataisytas vietoje: pridetas materializuotas `stage_rows` CTE, o abi `EXCEPT ALL` kryptys dabar skaito is jo. Iki vartotojui pateikiant atnaujinta faila remote pokytis nera laikomas pritaikytu.

Codex atliko tik leidziama read-only tunelio apzvalga. 19:59 UTC bukle: `requested_version=3237`, `completed_version=2707`, `pending`; `catalog_size_facets_read` vis dar yra uzpildytas senasis MV, o optimizuota stage tebera atskiras uzpildytas MV. Backup pavadinimas `catalog_size_facets_read_backup_20261017` dar neegzistuoja. Efektyvus view tebeturi priklausomybe nuo senojo canonical MV. Tai patvirtina, kad pagal stebeta katalogo busena perjungimas neivyko; klaidos atveju ankstesniu DDL transakcijos rezultatu savaime nepreziumuojame.

Kitas zingsnis: vartotojas turi is naujo ikelti pataisyta migracijos faila SQL Editor ir ji paleisti, cron paliekant sustabdytas. Po sekmingo vykdymo atskirai read-only patikrinsime canonical/backup/stage pavadinimus, ACL, view priklausomybe, source-stage sulyginimo irasa ir cron busena. Tai dar nera pilno 5 minuciu cron refresh irodymas; cron ijungimas lauks atskiro kontroliuoto pilno refresh ir jo trukmes / backlog patikros.

## 2026-10-17 20:05 UTC: stage paseno nuo gyvo dydziu saltinio

Po cutover apsaugos klaidos Codex palygino duomenis read-only, naudodamas tiksliai is migracijos UTF-8 failo paimta CTE. 20:05 UTC snapshot'e source turejo 367753, stage 367750 eiluciu; `EXCEPT ALL` rado 65 source-only ir 62 stage-only eilutes (127 skirtumu, 81 produktas). Visi 81 neatitinkantys produktai turejo `product_size_options.fetched_at` naujesni nei 2026-10-17 19:40 UTC. Nuo 19:40 UTC saltinyje atnaujintos 883 `product_size_options` eilutes 154 produktams. Tai patvirtina, kad stage po ankstesnio atnaujinimo paseno del velesniu dydziu parinkciu pakeitimu; vien cron sustabdymas siu saltinio rasymu nesustabdo.

Cutover migracija sustojo savo source-stage apsaugoje dar pries rename/revoke/view DDL. Nauja read-only patikra 20:07 UTC patvirtino, kad senasis canonical MV ir optimizuota stage abu tebepopuliuoti, backup pavadinimo nera, o refresh state yra `requested_version=3238`, `completed_version=2707`, `pending`.

Cutover migracija papildyta taip, kad po pradiniu cron/lock/owner/index/ACL apsaugu ji atnaujina tik shadow stage, o po to tame paciame `REPEATABLE READ` transakcijos snapshot'e perskaiciuoja source ir reikalauja tikslios eiluciu lygybes pries bet koki production pervadinima. Tai uzdaro atskiru stage refresh ir cutover tarpa, kuriame pasikeite dydziu saltinis. Naujausia SQL versija dar nepritaikyta VPS. Cron lieka sustabdytas; po sekmingo cutover bus atskira read-only patikra ir tik tada kontroliuojamas pilnas refresh bandymas.

## 2026-10-17 20:16 UTC: optimizuotas size MV cutover patvirtintas read-only

Vartotojas pateike tris production indeksus; visi `indisvalid=true`, `indisready=true`, unikalus `(product_id, token)` indeksas. Codex read-only tuneliu 20:16 UTC papildomai patvirtino, kad `catalog_size_facets_read` yra uzpildytas MV su trimis optimizuotais indeksais, 92 MB total dydziu, `service_role` SELECT ir be anon/authenticated SELECT. Senasis uzpildytas MV issaugotas `catalog_size_facets_read_backup_20261017` vardu (135 MB), API rolms prieigos neturi. `catalog_size_facets_read_effective` priklauso nuo naujo production MV ir neberodo i backup. Taigi cutover patvirtintas; backup paliekamas rollback galimybei.

Read-only state vis dar rodo `requested_version=3239`, `completed_version=2707`, tarpa 532, `pending`; paskutinis pilnas refresh buvo 2026-10-11 19:10 UTC. `catalog_items_read` planner/live eilutes sutampa paklaidos ribose (104792/104687), paskutine ANALYZE statistika yra. Refresh lock'u tikrinimo metu nebuvo. Codex `codex_reader` neturi SELECT teises i cron schema, todel dabartine cron aktyvumo busena is tunelio nepatvirtinta; naujas catch-up SQL pries vykdyma tikrina, kad jobas sustabdytas.

Parengtas vienkartinis post-cutover catch-up failas `20261017_catch_up_catalog_refresh_after_size_cutover_once.sql` ir atskira read-only patikra `verify_catalog_refresh_after_size_cutover_read_only.sql`. Jie dar nevykdyti. Po ju reikalausime `status=refreshed`, trukmes <300000 ms, uzdaryto version gap ir jokio refresh lock; cron lieka sustabdytas iki tu irodymu.

## 2026-10-17 20:22 UTC: vartotojo patikra patvirtino cutover ir sustabdyta cron

Vartotojo sujungta read-only patikra parode tris indeksu eilutes su pasikartojancia cutover busena: `cron_paused=true`, production MV uzpildytas (92 MB), savininkas `postgres`, SELECT turi tik `service_role`; senas backup uzpildytas ir nepasiekiamas anon/authenticated/service_role; effective view naudoja nauja MV ir atsietas nuo backup. Visi trys optimizuoti indeksai validus ir ready; unique indeksas yra unikalus. Tai uzbaigia cutover patvirtinima.

Refresh state dar `requested_version=3239`, `completed_version=2707`, tarpas 532, `pending`, paskutinis uzbaigimas 2026-10-11 19:10 UTC. Cron patvirtintas sustabdytas. Kitas leistinas zingsnis yra vienkartinis kontroliuotas catch-up su preflight apsaugomis; tada atskira read-only patikra patvirtins duration, gap, lock ir status. Cron neijungti, kol neirodyta, kad pilnas refresh uztrunka maziau nei 5 min. ir nepalieka backlog.

## 2026-10-17 20:26 UTC: catch-up preflight aptiko aktyvu refresh lock

Vartotojo vienkartinis catch-up failas sustojo apsaugoje `A catalog refresh lock is still held`; `process_catalog_items_read_refresh()` siame bandyme nebuvo iskviesta. Codex read-only tuneliu 20:26 UTC rado procesa PID 2138034, application `postgres-meta 0.0.0-automated`, kuris laike advisory lock `catalog_items_read_refresh` ir `ExclusiveLock` ant `catalog_items_read`. State liko `requested_version=3239`, `completed_version=2707`, `pending`; jokio naujo refresh uzbaigimo nera. `codex_reader` neturi teises matyti kito backend query/state detaliu, todel paruosta `diagnose_catalog_refresh_lock_holder_read_only.sql`, kuria SQL Editor postgres role gali parodyti sesijos query/start/state. Catch-up nekartoti, kol sesija identifikuota arba lock dinges, tada dar karta patikrinti state ir lock.

## 2026-10-17 20:31 UTC+: lock dingo, catch-up uzbaigtas, trukme virsija tiksla

Vartotojo SQL Editor read-only lock diagnostika 20:31:01 UTC grazino `NO_MATCHING_REFRESH_LOCK`, `requested_version=3239`, `completed_version=3239`, `last_status=refreshed`. Read-only tunelio patikra patvirtino ta pati uzbaigta state: `last_duration_ms=324124` (5 min. 24.124 s), be `last_error`; startas 20:24:24.019 UTC, pabaiga 20:29:48.144 UTC. Version gap uzdarytas ir refresh lock nebeliko, bet 5 min. vykdymo tikslo nepraejo. Todėl cron lieka sustabdytas; tai nera pagrindas laikyti periodini vykdyma patvirtintu ar ji ijungti.

Preflight klaida `A catalog refresh lock is still held` apsaugojo nuo antro lygiagretaus vykdymo. Tuo metu lock laike `postgres-meta 0.0.0-automated` backend'as; turimi duomenys neirodo, kuri sesija ji pradejo. Dabartine diagnostika parode, kad vykdymas veliau uzsibaige sekmingai. Taigi tai buvo aktyvaus darbo saugantis lock'as, ne SQL Editor teisiu klaida.

Read-only tunelio ACL patikra rodo `EXECUTE` `anon`, `authenticated`, `service_role` ir `postgres` rolms ant `request_catalog_items_read_refresh()` ir SECURITY DEFINER `process_catalog_items_read_refresh()`. Vidine `rebuild_catalog_items_read_internal()` prieinama tik `postgres`, kaip numato repo migracija. Gyva ACL neatitinka `20260714205054` migracijos `REVOKE` nuo anon/authenticated; repo paieska nerado velesnio aiskaus `GRANT` siam refresh. Priezastis dar nenustatyta (galimos VPS migraciju istorijos ar default privileges skirtumos), todel reikia tikslines read-only ACL/default-privileges ir migraciju istorijos diagnostikos. Jokios remote teises nekeistos.

## 2026-10-17 20:45 UTC: dabartinis bloat snapshot ir matavimo ribos

Leidziama `codex_reader` tunelio patikra 20:45 UTC parode viena nauja laukima:
`requested_version=3240`, `completed_version=3239`, gap 1, `pending`;
prasymas gautas 20:37:48 UTC po ankstesnio catch-up. Cron vis dar pristabdytas,
todel naujas request nera apdorotas. Paskutinis refresh ir jo 324124 ms trukme
nepasikeite.

Read-model statistika tuo metu: `catalog_items_read` 0 dead tuples, heap 1026
MB, total 6300 MB; paskutinis autovacuum 20:33:35 UTC. `catalog_item_facet_values_read`
0 dead tuples, heap 202 MB, total 442 MB; autovacuum 20:30:18 UTC.
`catalog_size_facets_read` 5314 dead tuples, heap 36 MB, total 95 MB;
autovacuum 20:14:51 UTC. `catalog_effective_size_membership_read` 29135 dead
tuples, heap 54 MB, total 90 MB; paskutinis autovacuum 2026-10-09 08:04 UTC.
Abieju didziuju read modeliu reloptions nera, o items ir facet-values MV turi
specialius `500 + 2%` vacuum/analyze slenkscius. MV `n_tup_ins/n_tup_del`
skaitikliai dideli, bet tai kumuliatyvios statistikos ir nepateikia atskiro
prieaugio vienam refresh; DB statistikos reset laikas nezinomas.

Gyvi PostgreSQL globalus vacuum nustatymai yra `autovacuum_vacuum_threshold=50`
ir `autovacuum_vacuum_scale_factor=0.2`. Be per-table override, 374061 gyvu
effective membership eiluciu reiskia apytikri 74862 dead-tuple slenksti;
29135 dabartiniu dead tuples dar jo nepasieke, todel spalio 9 d. paskutinio
autovacuum data su dabartiniu skaiciumi yra suderinama. 377110 dydziu MV eiluciu
numatytasis slenkstis butu apie 75472, gerokai virs dabar matuojamu 5314.
Tai reiskia, kad heavy refresh sukurtas dead tuples gali ilgai likti siuose MV,
nors items ir facet-values MV specialus 2% slenkstis isvalo dazniau. Tai yra
MVCC dead-tuples paaiskinimas; tikslios fizines bloat apimties vien is siu
statistiku nustatyti negalima.

Kodo kelias patvirtina skirtuma: `clean` saka atnaujina tik viena state
singleton eilute ir grizta pries rebuild; ji neatnaujina MV. Todel tuscias
cron patikrinimas negali tiesiogiai sukurti dead tuples 6.3 GB
`catalog_items_read` ar kitu MV heap'uose. Dideli MV dead tuples ir fizinio
perrasymo kaina atsiranda nuo realaus `REFRESH ... CONCURRENTLY` darbo; tuscias
kvietimas gali tureti tik maza state lenteles MVCC kaina. Dabartiniai 0 dead
tuples items/facet-values lentelese po autovacuum nepaneigia ankstesnio churn.

Tikrojo clean/refreshed skaiciaus per tuneli dar gauti nepavyko: `codex_reader`
neturi `cron` schemos teisiu, `extensions.pg_stat_statements` USAGE, o
`track_functions=none`. Repo yra faziu logavimo instrumentacija ir gyvoje DB
funkciju apibrezimuose jos markeriai yra, taciau `docker logs` anksciau
nepateike irasu. Paruostas [vieno lango read-only refresh istorijos reportas](../../supabase/tests/diagnose_catalog_refresh_run_history_read_only.sql)
SQL Editor postgres rolei; jo cron run trukmes ir `pg_stat_statements` apskaiciuos,
bet `cron.job_run_details` `succeeded` pats savaime neatskiria `clean` nuo
`refreshed`. Tiksli faziu istorija reikalauja `catalog_refresh_phase` log eiluciu
pagal `run_id`; jei jos nerenkamos is konteinerio logu, ateityje reikes
atskiro isliekančio run/phase metrikos dizaino pries darant dazniu isvadas.

## 2026-10-17 20:48 UTC: 14 dienu cron ir statistiku reportas

Vartotojo SQL Editor reportas uzfiksavo cron konfiguracija: job `1`,
`*/5 * * * *`, `active=false`, SQL lygmens `statement_timeout='5min'` ir
`lock_timeout='3s'`. `cron.job_run_details` saugojimo lange (2026-10-03
20:50–2026-10-11 13:06 UTC) buvo 2212 iskvietimu: 2211 `succeeded`, 1
`failed`; vidutine trukme 150.157 s, mediana 236.121 s, p95 300.430 s,
ilgiausias 303.671 s. Naujausiuose 60 irasu 59 is 60 truko bent 295 s
(mediana 300.364 s); likusi nesekme truko 93.301 s ir turejo pranesima
`job canceled`. Visi 59 sekmingi irasai turejo vienoda `return_message='1 row'`.
Tai reiskia, kad paskutiniame iki sustabdymo intervale cron vykdymai beveik
nuolat pasiekdavo 5 minuciu riba. Vien `succeeded` ar `1 row` neirodo, kad
read modelis buvo atnaujintas; bet si trukmiu seka tikrai nera panasi i daug
greitu `clean` patikrinimu.

`pg_stat_statements` reporte `process_catalog_items_read_refresh()` turi 1944
kvietimus, 314,893,113 ms bendra vykdymo laika, 161,982 ms vidurki ir
720,441 ms maksimuma. Tai kumuliatyvi statistika, ne istorinis kiekvieno
kvietimo rezultatas; jos reset momentas nepateiktas. Taigi ji patvirtina didele
funkcijos vykdymo kaina, bet neleidzia pasakyti, kiek kvietimu buvo `clean`,
`refreshed`, `busy` ar nesekmingi, ir neleidzia faziu laiko paskirstyti
konkretiems run'ams. Paskutinis patvirtintas sunkus refresh buvo 324.124 s
(20:24:24–20:29:48 UTC); po jo 20:37:48 UTC gautas naujas request, todel
dabartine state yra `requested_version=3240`, `completed_version=3239`, gap 1,
`pending`. Cron lieka sustabdytas.

Vartotojo serveryje abu bandymai su `docker logs --since=24h` ir
`--since=200h`, filtruojant `catalog_refresh_(run|phase)`, grazino tuscia
rezultata. DB funkciju apibrezimuose log markeriai yra, tad truksta ne
instrumentacijos, o prieinamo logu kanalo/retencijos. Kol kas faziu trukmiu
istorijos is pateiktu irodymu gauti negalima. Pries keiciant cron ar cache TTL
reikia issiaiskinti PostgreSQL log destination ir ar faziu irasai pasiekiami
kitame VPS logu kanale. Jei jie neissaugomi, kitas dizaino zingsnis – prideti
isliekančia run/phase metrika, kuri atskirai fiksuotu `clean`/`busy`/`refreshed`,
versiju tarpa, faziu ms ir klaidas; tada kontroliuojamai rinkti duomenis.

Sios ataskaitos duomenys atskiria tiesiogini bloat mechanizma: `clean` saka
neatnaujina didziuju MV, todel tuscios patikros negali paaiskinti ju dead tuple
skaiciu. Didziuju MV dead tuples ir perrasymo darba sukuria realus refresh'ai.
Tuščiu kvietimu kiekis vis dar svarbus CPU/DB apkrovai, bet esami 14 d. vykdymo
laikai rodo, kad iki cron sustabdymo problema neapsiribojo tuščiais poll'ais.
Vien sios ataskaitos nepakanka galutiniam 5 ar 10 min grafiko, timeout ar cache
TTL pasirinkimui; ju nekeiciame, kol neturime faziu ir cache galiojimo matavimu.
