# Katalogo filtravimo patobulinimų planas

**Atnaujinta:** 2026-10-09 (Europe/Vilnius)
**2026-10-09 dydžių standartizavimo tikslas:** naudotojas patikslino, kad naujos
prekės turi būti automatiškai normalizuojamos ta pačia taisykle per katalogo
atnaujinimą, be rankinio kiekvienos prekės klasifikavimo. Paruošta
[20261009100000 dydžių standartizavimo migracija](../../supabase/migrations/20261009100000_standardize_apparel_size_facets.sql):
aiškius drabužių alpha dydžių aprašus suveda į S–8XL standartinius raktus;
intervalus, pvz. `S–M`, priskiria abiem standartiniams pasirinkimams; kelnių
`W × L` užrašymo variantus suvienodina išsaugant skirtingus liemens ir ilgio
dydžius. Neaiškūs skaitiniai ar intervaliniai dydžiai nekeičiami, todėl jų
klasifikavimui dar reikia kategorijos / dydžių sistemos taisyklių. Migracija dar
nepritaikyta VPS. Pirmasis 2026-10-09 bandymas nepavyko su
`invalid regular expression: parentheses () not balanced`; dvi neprivalomo
aprašo grupavimo išraiškos pataisytos. Migracijos DDL vėliau sėkmingai paleistas
SQL Editor (`Success. No rows returned`), o naudotojo patikroje abi naujos
funkcijos yra. `invalidate_catalog_facets_cache()` SQL Editor grąžino Zod
validavimo klaidą, tačiau read-only VPS patikra 09:10:32 UTC rado atnaujintus
static ir bendrą facetų cache įrašus su tuo pačiu laiku bei **372 818** narystės
eilučių (prieš tai buvo 375 751). Materializuotoje narystėje drabužių ir
marškinių dydžiai jau pateikti standartiniais S–8XL raktais. Tai patvirtina, kad
refresh įvyko nepaisant SQL Editor rezultatų atvaizdavimo klaidos. Codex reader
neturi naujų helper funkcijų EXECUTE teisės, todėl pilnas view ir materializuotos
narystės pariteto palyginimas nebuvo vykdomas. Toliau reikia tik patikrinti
facetų pasirinkimus produkto UI; papildomo SQL paleisti nereikia.
**Bendras progresas:** 20/100 – 0 etapas patikrintas, 1–4 etapai dar nepriimti; dalinis įgyvendinimas balų neprideda.
**Dabartinė būsena:** istorinis 120 miss/hit porų API matavimas tebelieka **240/240 HTTP 200**, miss p95 **4,643 s**, hit p95 **0,354 s**; tai nėra naujas matavimas. Po migracijos žinomi ciklai `2293/2293 clean` per **251,669 ms**, `2295/2295 clean` per **259,760 ms** ir `2303/2303 clean` per **274,426 ms**; visų `last_error=NULL`, abiejų vaizdų `last_analyze` atnaujintas 2303 cikle. Tarpinių versijų istorinių įrašų nėra, todėl trijų iš eilės ciklų priėmimo patvirtinti negalima. Per 09:17–09:22 UTC read-only patikroje `catalog_static_size_facets_cache` SELECT teisė buvo `true`; ciklo 2303 cache atnaujintas 09:05:00.026390 UTC, cache ir tikėtina agregacija turėjo po **2434** facetus, JSON payload sutapo tiksliai, narystė turėjo **374466** eilučių. Taigi cache/narystės paritetas patvirtintas šiam momentiniam ciklui. `pg_stat_io` skaitymas veikė ir 09:22:12.941386 UTC užfiksuota backend_type kaupiamų skaitiklių bazė, tačiau `track_io_timing=off`; tai nėra vieno refresh ciklo disko I/O matas. `pg_stat_statements` yra `extensions` schemoje, bet `codex_reader` neturi prieigos. Host CPU/disko metrikos neišmatuotos. Reikia patvirtinti tris iš eilės natūralius clean ciklus <300 s, suderintas versijas ir jų cache narystės paritetą. Produkcinio API laikas/statusas, mobile/kelių skirtukų scenarijai ir produkcinio bundle tapatybė atviri. Progresas lieka 20/100; etapai 1–4 nepriimti. Naudotojas pranešė pritaikęs migraciją, SQL Editor „Success“ išvesties nėra. [Spalio 5–7 d. eiga](ATNAUJINIMO_EIGA_2026-10-05.md). Nauji `other_sizes` API ir alert payload vietiniai pakeitimai necommitinti ir neįtraukti į ankstesnį Pages auto-update commit `b515758`; produkcinis revision neidentifikuotas.

**2026-10-05 eiga (tos dienos momentinė būsena):** [neblokuojančio refresh bandymas ir patikros](ATNAUJINIMO_EIGA_2026-10-05.md). VPS funkcijoje matomas `CONCURRENTLY`; trys stebėti ciklai sėkmingi per 251,889, 254,181 ir 252,060 s, o naudotojo SQL Editor patikroje `cache_matches_membership = true`. 2107 ciklo metu DB dydžių vaizdo ir katalogo riboti skaitymai nebuvo blokuoti. [Pirmame API segmente](API_BANDYMAS_2026-10-05_01.jsonl) gautos 45 galiojančios poros, [ketvirtame](API_BANDYMAS_2026-10-05_04.jsonl) – dar 75; bendra unikali imtis **120/120**, po 20 kiekvienoje iš šešių grupių. Bendras miss p50/p95 **3,537/4,643 s**, hit p50/p95 **0,181/0,354 s**, didžiausias miss **6,215 s**. [Antrame](API_BANDYMAS_2026-10-05_02.jsonl) ir [trečiame](API_BANDYMAS_2026-10-05_03.jsonl) segmentuose užfiksuoti keturi HTTP 401 dėl sesijos; jie į našumo imtį neįtraukti. Spalio 5 d. atskira SQL Editor migracijos „Success“ išvestis dar nebuvo gauta, o produkto API prieinamumas aktyvaus refresh metu dar nebuvo patikrintas; vėlesnės patikros aprašytos aukščiau ir [eigoje](ATNAUJINIMO_EIGA_2026-10-05.md).

Šis skyrius yra **einamasis planas**. Toliau esanti 2026-07-31 analizė yra istorinis auditas: jos senos būsenos ir procentai neaprašo dabartinės VPS ar kodo būklės. Keičiant etapo būseną būtina čia pat įrašyti datą, rezultatą ir nuorodą į patikros įrodymą. `patikrinta` reiškia, kad veikia reikalingas kodas, o VPS pakeitimo atveju naudotojas pateikė sėkmingą „SQL Editor“ vykdymo rezultatą ir atskirai užfiksuota skaitymo režimo patikra.

## Dabartinė atskaitos vieta

[Spalio 4 d. VPS analizė](KATALOGO_FILTRAVIMO_VPS_ANALIZE_2026-10-04.md) nustatė, kad produktų puslapis užtruko 155–187 ms, o pagrindinė gaištis yra nuosekliai skaičiuojami facetai po cache miss. [Pakartotiniai matavimai](KATALOGO_FILTRAVIMO_MATAVIMAI_2026-10-04.md) po `20261004100000_optimize_catalog_facet_prefilter.sql` rodė „žemiau LPL + juoda“ sumažėjimą nuo 10,051 iki 6,891 s, o „tik juoda“ liko 10,915 s. Po trijų naujų migracijų abu scenarijai sumažėjo atitinkamai iki 2,239 ir 5,126 s. Tai tiesioginių SQL kūnų, o ne viso RPC ar API p95, matavimai. `authenticator` užklausos limitas VPS yra 8 s.

## Etapai ir įrodymai

| Etapas | Būsena | Užbaigimo įrodymas |
| --- | --- | --- |
| 0. Atskaitos vieta ir pirminis SQL pakeitimas | **patikrinta** | [2026-10-04 matavimai](KATALOGO_FILTRAVIMO_MATAVIMAI_2026-10-04.md); VPS patvirtinta bendro filtro vieta SQL plane. |
| 1. Effective dydžių narystės našumas | **vykdoma** | Read-only patikra patvirtino gyvos funkcijos owner `postgres`, ANALYZE/order guard ir invalidation guard'us (`true`); SQL Editor „Success“ išvestis nepateikta. Žinomi ciklai: `2293/2293 clean` **251,669 ms** (06:55:00.025–06:59:11.694 UTC), `2295/2295 clean` **259,760 ms** (07:05:00.024519–07:09:19.784814 UTC), `2303/2303 clean` **274,426 ms** (09:05:00.029–09:09:34.455 UTC); visi `last_error=NULL`, 2303 cikle analyze: items 09:05:17.480287 UTC / size 09:07:15.593890 UTC. Tarpinių versijų istorinių įrašų nėra, todėl trijų iš eilės ciklų dar negalima patvirtinti. 2303 ciklui cache/narystės paritetas patikrintas: 2434/2434 facetai, JSON tiksliai sutampa, narystė 374466 eilučių. `pg_stat_io` kaupiamoji bazė paimta 09:22:12.941386 UTC, bet `track_io_timing=off`; host CPU/disko metrikų nėra, `pg_stat_statements` prieigos `codex_reader` neturi. Reikia patvirtinti tris iš eilės natūralius clean ciklus <300 s, sutampančių versijų ir cache pariteto patikrą. |
| 2. Filtrų ir alertų rezultatų tikslumas | **vykdoma** | Vietinė API regresija atskleidė ir pataisė `other_sizes` masyvo literal dešimtainio kablelio apdorojimą; realių DB/API kiekių pariteto priėmimas dar laukia. |
| 3. Cache ir UI patikimumas | **vykdoma** | Vietinis 5 min. cache, invalidavimo/užklausų pataisų regression testai ir alert payload pure extraction patikrinti. Pilnas UI priėmimas atviras: production bundle/revision nepatvirtintas; API statuso/laiko, mobile, trijų skirtukų ir dalies gedimo scenarijų įrodymų nėra. Naudotojas pranešė paleidęs automatinį Pages atnaujinimą, tačiau Wrangler sąrašo patikra nepavyko dėl trūkstamo API tokeno neinteraktyvioje aplinkoje; tokenų neieškota. |
| 4. Galutiniai matavimai ir uždarymas | **vykdoma** | [120 porų istorinis rezultatas](ATNAUJINIMO_EIGA_2026-10-05.md): 240/240 HTTP 200, miss p95 4,643 s, hit p95 0,354 s. Naujausi du natūralūs refresh įrašyti atskirai; jie nesudaro trijų ciklų priėmimo, o katalogo/facetų API 200 ir <8 s per šiuos ciklus nepatikrinta. Liko refresh pataisos ir frontend produkcinis priėmimas. |

### 2026-10-04 įgyvendinimo įrašas

Lokaliai paruoštos trys nuoseklios migracijos. 2026-10-04 skaitymo režimu VPS jau matomi trečios migracijos pagalbiniai normalizavimo metodai, atnaujintas effective dydžių vaizdas ir `catalog_facets_cached()` apibrėžimas; tai patvirtina, kad pakeitimai įrašyti DB. Materializuotoje narystėje yra **364 401** eilutė, **0** dešimtainio kablelio tokenų ir **0** likusių išvardytų nenormalizuotų „vieno dydžio“ tokenų; `catalog_facets_cache` yra tuščias. SQL Editor paskutinės užklausos atsakyme pateikė kliento validavimo klaidą (`code` ir `formattedError` trūko), o ne PostgreSQL sėkmės išvestį. Todėl pagal VPS taikymo taisyklę **formalus migracijų vykdymo patvirtinimas dar laukiamas**; ši skaitymo režimo patikra registruojama atskirai. Migracijos iš naujo neleisti vien dėl šio SQL Editor pranešimo. [Keturi skaitymo režimo našumo planai](KATALOGO_FILTRAVIMO_MATAVIMAI_2026-10-04.md) jau išmatuoti, tačiau API p95 po šių migracijų dar neišmatuotas.

Naudotojas pateikė trijų patikros SQL rezultatų dalis: `sample_mismatches = 0`, penki filtrų semantikos apibrėžimų požymiai yra `true`, `decimal_comma_tokens = 0` ir `unnormalized_one_size_tokens = 0`. Codex papildomai skaitymo režimu patvirtino keturis effective modelio struktūros požymius (`true`) ir tuos pačius penkis semantikos požymius (`true`). Tai patvirtina modelio struktūrą, 20 produktų narystės imtį ir nurodytų normalizavimo tokenų nebuvimą materializuotame rezultate; dar trūksta pagalbinių funkcijų reikšmių iš normalizavimo patikros pirmos lentelės ir elgsenos scenarijų.

1. [Effective dydžių read modelis](../../supabase/migrations/20261004110000_materialize_catalog_effective_sizes.sql) ir [jo skaitymo režimo patikra](../../supabase/tests/verify_catalog_effective_sizes_read_only.sql). VPS materializuotas modelis užpildytas, keturi struktūros požymiai yra `true`, 20 produktų imtyje `sample_mismatches = 0`; keturi SQL planai išmatuoti, liko refresh sąnaudos.
2. [Filtrų ir alertų semantika](../../supabase/migrations/20261004120000_align_catalog_filter_semantics.sql) ir [jos patikra](../../supabase/tests/verify_catalog_filter_semantics_read_only.sql). Penki apibrėžimų požymiai yra `true`, keturi SQL planai išmatuoti; realius produktų bei facetų kiekius dar reikia patikrinti.
3. [Dydžių tokenų normalizavimas](../../supabase/migrations/20261004130000_normalize_effective_catalog_sizes.sql) ir [jo patikra](../../supabase/tests/verify_catalog_size_normalization_read_only.sql). Materializuotų nenormalizuotų tokenų kiekiai yra `0`; dar reikia pagalbinių funkcijų rezultatų bei senų URL ir alertų tokenų suderinamumo patikros.

API ir web kodo pakeitimus diegti **po visų trijų migracijų**, nes admin override API naudoja antrame faile sukurtas RPC funkcijas, o URL dydžių tokenai remiasi trečio failo normalizavimu. Lokaliai praėjo 163/163 testų ir API, web bei shared TypeScript patikros. Tai nepatvirtina VPS SQL vykdymo, realių facetų kiekių, cache miss p95 ar desktop/mobile elgsenos.

Skaitymo režimu patikrinta dabartinės VPS funkcijų nuosavybė: šiomis migracijomis keičiamos funkcijos ir vaizdai priklauso `postgres`; `postgres` turi `EXECUTE` teisę atskirai `supabase_admin` valdomai statinio dydžių cache funkcijai. Naujos dydžių bei ne dydžių SQL užklausų ir alerto predikato išraiškos buvo suplanuotos su `EXPLAIN` dabartinėje VPS, laikinai pakeitus dar nesukurtą read modelį esamu vaizdu ir neprieinamus pagalbinius apvalkalus skaitymo režimo atitikmenimis. Tai sintaksės ir plano patikra, **ne** naujų migracijų našumo matavimas.

### 1 etapas – dydžių facetų našumas

- [x] Įdėtas [effective dydžių narystės read modelis](../../supabase/migrations/20261004110000_materialize_catalog_effective_sizes.sql): katalogo ir override keliai perskaičiuoja narystę ir invaliduoja facetų cache, o kontekstiniai facetai jungia atrinktus produktų ID su paruošta naryste. Modelis ir elgsena matomi VPS skaitymo režimu; ankstesnių 20261004110000–20261004130000 migracijų SQL Editor „Success“ išvestys registruojamos atskirai.
- [x] Yra unikalus `(product_id, token)` indeksas. 2026-10-07 VPS skaitymo režimu narystės duomenys užėmė **38 MB**, indeksas **24 MB**, kartu **62 MB**; viso katalogo refresh trukmės užfiksuotos [eigoje](ATNAUJINIMO_EIGA_2026-10-05.md). Atvirkštinis indeksas nepridėtas, nes jo poreikis neįrodytas planu.
- [x] Išsaugota facetų API struktūra ir įgyvendinti kontekstiniai dydžių kiekiai bei savos filtro grupės ignoravimas. Tai patvirtina [SQL apibrėžimas](../../supabase/migrations/20261004120000_align_catalog_filter_semantics.sql) ir vietiniai API testai; realių kombinacijų kiekių priėmimas lieka 2 etape.
- [x] Paruoštos pilnos [read modelio](../../supabase/migrations/20261004110000_materialize_catalog_effective_sizes.sql), [semantikos](../../supabase/migrations/20261004120000_align_catalog_filter_semantics.sql) ir [normalizavimo](../../supabase/migrations/20261004130000_normalize_effective_catalog_sizes.sql) migracijos, atskiri skaitymo režimo patikros SQL ir vietiniai elgsenos testai. Šis punktas reiškia artefaktų parengimą, o ne formalų VPS taikymo patvirtinimą.
- [x] [Pilno effective dydžių refresh pakeitimas](../../supabase/migrations/20261004140000_unblock_effective_size_refresh.sql), [fazės žymėjimas](../../supabase/migrations/20261004150000_label_catalog_refresh_failure_phase.sql) ir [statinio žodyno skaičiavimas iš paruoštos narystės](../../supabase/migrations/20261004160000_reuse_effective_membership_for_static_sizes.sql) turi atskiras SQL Editor „Success“ išvestis [matavimo žurnale](API_MATAVIMO_ZURNALAS_2026-10-04.md). Vėlesnis [neblokuojantis refresh](../../supabase/migrations/20261005090000_nonblocking_effective_size_refresh.sql) matomas VPS; keli natūralūs ciklai baigėsi sėkmingai, o autentifikuoti katalogo ir facetų API atsakė HTTP 200 per aktyvų ciklą. [Statinio cache patikra](../../supabase/tests/verify_catalog_static_size_reuse_read_only.sql) rodė sutapimą su naryste; paruoštos narystės grupavimas atskirai užtruko **625,366 ms**.
- [ ] Atskirai užregistruoti 20261004110000–20261004130000 ir 20261005090000 SQL Editor sėkmės išvestis, jei jos buvo gautos; VPS apibrėžimų buvimas ir skaitymo režimo patikros nėra šių konkrečių vykdymų formalus patvirtinimas.
- [ ] Išmatuoti hosto CPU ir disko sąnaudas bei priimti 300 s refresh pataisą. Du nesėkmingi ciklai baigėsi `effective_size_membership` fazėje, tačiau ~112 s fazės trukmė sunaudojo likusią ankstesnių nuoseklių etapų paliktą 300 s biudžeto dalį. Po `ANALYZE` žinomas 2303 ciklas truko 274,426 ms; jo cache/narystės paritetas patikrintas (2434 facetai, tiksliai sutampantis JSON, 374466 narystės eilučių). Kitų tarpinių ciklų istorija nepasiekiama, todėl trijų iš eilės ciklų priėmimas lieka nepatvirtintas. `pg_stat_io` kaupiami skaitikliai turi tik 09:22:12.941386 UTC bazinį mėginį, o `track_io_timing=off`; tai neatstoja per-ciklo disko mato. `pg_stat_statements` skaityti neleidžia `codex_reader`. Cloud Supabase atveju naudoti Dashboard resursų grafikus; savame VPS CPU/diskui rinkti hosto OS skaitiklius (`vmstat`, `iostat`, `pidstat`). Nuolatinis monitor agentas neįdiegtas. Reikia trijų patvirtintų iš eilės natūralių ciklų <300 s, sutampančių versijų ir kiekvieno ciklo cache pariteto.
- [x] Po pritaikymo pakartoti keturis spalio 4 d. `EXPLAIN (ANALYZE, BUFFERS)` scenarijus vienodais filtrais ir palyginti su baziniais bei naujausiais planais. [Rezultatai ir žali planai](KATALOGO_FILTRAVIMO_MATAVIMAI_2026-10-04.md).

### 2 etapas – rezultatų tikslumas

- [ ] Galutinai sutikrinti produktų, ne dydžių facetų, dydžių facetų ir alertų grupuotų bei senų dydžių tokenų narystę. SQL jau įgyvendina `OR` vienoje grupėje, `AND` tarp grupių ir savos grupės ignoravimą; trūksta realių alertų, legacy tokenų ir facetų kiekių pariteto patikros.
- [ ] Patikrinti realius `lplProximityPct` ir `otherSizes` rezultatus bei kiekius. Bendro filtro ir atsakymo SQL kelias įgyvendintas, tačiau vien apibrėžimo patikra neįrodo rezultatų tikslumo.
- [ ] Patvirtinti `42,5`, „vieno dydžio“, `W × L`, nežinomų reikšmių ir senų URL bei alertų tokenų elgseną. Normalizavimo SQL yra, o produkciniame UI `42,5` paieška veikia; pagalbinių funkcijų laukiamų išvesčių ir visų suderinamumo scenarijų dar neužfiksuota.
- [ ] Užbaigti kategorijos, „juoda“, „žemiau LPL“, jų kombinacijos, grupuoto ir seno dydžio, override bei alerto rezultatų patikrą. Kategorijos, juodos spalvos, kelių dydžių ir „Galaxy“ pataisos dalis užfiksuota [eigoje](ATNAUJINIMO_EIGA_2026-10-05.md); trūksta likusių realių kiekių ir pilno keturių našumo planų pakartojimo po semantikos pakeitimų.

### 3 etapas – cache ir sąsajos patikimumas

- [ ] Užbaigti ir produkcijoje priimti facetų cache elgesį. Vietiniame [katalogo puslapio kode](../../apps/web/pages/index.vue) atminties ir `localStorage` cache taiko 5 min. ribą; invalidavimas per saugyklos įvykį panaikina senų užklausų teisę keisti UI ar cache. Regresijos padengtos vietiniais testais; desktop produkcijoje patikrinti kelių pasirinkimų apply/cancel, Back/Forward, reload, Escape/meniu ir `42,5`. Pirmas facetų prašymas parodė klaidą, retry atitaisė, tačiau statusas ir trukmė nefiksuoti. Nepriimta produkcijoje: nauja pataisa dar nedeployinta, API 200/<8 s, mobile, trijų skirtukų invalidavimas ir gedimų scenarijai.
- [x] Vietiniame [katalogo puslapio kode](../../apps/web/pages/index.vue) produktų užklausos turi sekos numerį ir atšaukimą, o facetų atsakymai tikrinami pagal seką; klaidos atveju paliekami paskutiniai facetai ir rodoma klaida su pakartojimo veiksmu. Šios lenktynių ir timeout elgsenos produkcijoje bei komponento testu dar nepatikrintos.
- [ ] Galutinai patvirtinti atidaryto filtrų meniu stabilumą, pasirinktų nulinio kiekio reikšmių išlaikymą ir kelių pasirinkimų taikymą desktop bei mobile. [Komponente](../../apps/web/components/CatalogFilters.vue) yra snapshot ir draft/apply logika; produkcijoje rankiniu būdu patikrintas tik vieno dydžio mobile pasirinkimas.
- [ ] Patikrinti greitą kelių dydžių žymėjimą, lėtą tinklą, puslapio perkrovimą, naršyklės istoriją ir klaviatūros valdymą. Šių bendrų UI priėmimo scenarijų įrodymo dar nėra.

### 4 etapas – galutinis patvirtinimas

- [x] Išmatuoti tikro API kelio cache miss ir hit p50/p95; atrinktoje 120 porų imtyje miss p95 **4,643 s**, t. y. **3,357 s** žemiau 8 s ribos. [Rezultatai](ATNAUJINIMO_EIGA_2026-10-05.md). Pageidautina 1–2 s trukmė dar nepasiekta; matavimą pakartoti kitu metu.
- [x] API matavimui atrinkti 120 skirtingų galiojančių filtrų kombinacijų iš šešių grupių ir pakartoti kiekvieną cache hit matavimui. Įrašyti bendri miss ir hit p50/p95, kiekvienos grupės mediana bei maksimumas, timeout skaičius, katalogo versijos ir matavimo laikas; naudotas autentifikuotas aplikacijos kelias.
- [ ] Per katalogo refresh ir override pamatuoti hosto CPU, disko prieaugį, atnaujinimo trukmę ir cache teisingumą. DB `pg_stat_io` mėginys yra kaupiamas nuo serverio statistikos pradžios, o ne susietas su konkrečiu refresh; `track_io_timing=off`. Hosto metrikoms cloud atveju tikrinti Supabase Dashboard, savame VPS – OS įrankių (`vmstat`/`iostat`/`pidstat`) laiko eilutę; monitor agentas neįdiegtas.
- [x] 8 s API priėmimo riba pasiekta: 120 porų imties cache miss p95 yra **4,643 s**, todėl sąlyginis papildomo API optimizavimo žingsnis šiuo metu netaikomas. Pageidautinas 1–2 s atsakas dar nepasiektas; naujai aptiktas 300 s refresh timeout tiriamas 1 etape. Atskirą paieškos paslaugą svarstyti tik palyginus jos naudą ir priežiūros kainą.
- [ ] Įrašyti galutinius rezultatus, atnaujinti etapų būsenas ir `docs/TURINYS.md` progresą.

### API matavimo ir scenarijų metodas

Keturi pakartojami `EXPLAIN` scenarijai yra istorinė našumo atskaitos vieta, bet jų neužtenka nei API p95, nei filtrų semantikai patikrinti. API scenarijus padalyti bent į šešias grupes po 20 skirtingų, realius produktus atitinkančių kombinacijų: be filtro arba vienas platus filtras; kategorija ir spalva; keli skirtingų grupių filtrai; dydis ir kitos dydžių reikšmės; kainos / nuolaidos / LPL sąlygos; reti ar labai siauri deriniai. Atrinkti ir populiarias, ir retas reikšmes; nulinių rezultatų atvejus tikrinti atskirai, kad jie dirbtinai nepagreitintų p95. Atskirais korektiškumo scenarijais patikrinti kelių reikšmių `OR` vienoje grupėje, `AND` tarp grupių, savos grupės ignoravimą, kategorijos kelią, `42,5`, „vieno dydžio“ ir senus tokenus, override, `otherSizes`, alertus bei cache invalidavimą.

Matuoti `GET /v1/catalog/facets` iš prisijungusio naudotojo sesijos, siunčiant užklausas nuosekliai ir nepaleidžiant DB cache rašančio RPC tiesiai per `codex_reader`. Pradėti nuo 12–20 užklausų bandomosios serijos, tada tęsti iki 120, jei nėra timeout ar pastebimo VPS apkrovos šuolio. Šiame API kelyje nėra atskiro edge cache, tačiau web `localStorage` turi 5 minučių facetų cache; matavimo klientas turi kviesti API tiesiogiai ir nenaudoti to browser cache. Prieš kiekvieną pirmą užklausą skaitymo režimu patvirtinti, kad normalizuoto filtro rakto nėra `catalog_facets_cache`; po jos – kad įrašas atsirado. Tą patį URL pakartoti antrą kartą ir patvirtinti, kad įrašo `created_at` nepasikeitė. Nemodifikuoti ar neišvalyti cache vien tam, kad susidarytų miss; negeneruoti atsitiktinių parametrų, kuriuos API ignoruoja. Kiekvienai užklausai fiksuoti visą HTTP trukmę, būseną ir timeout / klaidą, bet nesaugoti prisijungimo žetono. Matavimą vykdyti tarp katalogo atnaujinimų, be papildomos lygiagrečios apkrovos, ir pakartoti kitu metu, jei rezultatai arti 8 s ribos. Šie 120 matavimų leidžia vertinti bendrą p95; kiekvienos 20 atvejų grupės p95 nelaikyti tiksliu, todėl grupėms pateikti medianą ir maksimumą. Kadangi API užklausa po cache miss įrašo naują DB cache eilutę, projekto nuolatinis `codex_reader` leidimas šiam aktyviam matavimui negalioja; jį vykdo naudotojas arba Codex gavęs atskirą leidimą naudoti prisijungusią aplikacijos sesiją.

## VPS migracijų taisyklė

Kiekvienam DB pakeitimui paruošti atskirą pilną failą `supabase/migrations/` ir skaitymo režimu vykdomą patikros SQL su laukiamu rezultatu. Naudotojas pats įkelia naujausią failo turinį į VPS „Supabase SQL Editor“ ir paleidžia. VPS pritaikymas laikomas patvirtintu tik gavus sėkmingo vykdymo išvestį; Codex per PuTTY tunelį gali atskirai atlikti tik skaitymo režimo diagnostiką. SQL klaidos atveju pirmiausia tirti esamą būseną, nelaikant ankstesnių sakinių automatiškai atšauktais.

## Istorinis 2026-07-31 auditas ir ankstesnis planas

Žemiau esanti medžiaga saugoma kaip ankstesnių sprendimų ir neatitikimų istorija. Jos TODO varnelės paliktos tokios, kokios buvo ankstesniame audite; jos nėra einamojo plano progreso matas. Dabartiniai vykdytini punktai yra tik aukščiau esantys 1–4 etapai.

## 2026-07-31 commit `5cf9817` atitikties auditas

Audituotas paskutinis commit `5cf9817fcda93b9b76b3962b07707a9ec3baa7d9`
(`feat: Implement size classification and caching improvements`). Vertintas commit diff,
galutinė migracijų būsena, API, web ir vietiniai testai. VPS Supabase nebuvo
jungiamasi, todėl migracijų pritaikymas ir realių duomenų rezultatas šiame audite
laikomi **nepatikrintais**, o ne įvykdytais.

Žymėjimas šiame skyriuje:

- **BLOKUOJA** – pažeidžia priėmimo kriterijų arba gali pateikti neteisingą rezultatą;
- **DALINAI** – kodo dalis yra, bet visas plano punktas neįgyvendintas;
- **NEPATIKRINTA** – nėra DB, integracinio, komponento ar E2E įrodymo.

### Kritiniai neatitikimai

1. **BLOKUOJA – dydžių facetas nebėra kontekstinis.** Galutinė
   `202607300009_cache_static_size_facets.sql` funkcija
   `catalog_grouped_size_facets(p_filters)` parametro `p_filters` nenaudoja ir
   visoms užklausoms grąžina tą patį statinį dydžių sąrašą. Pasirinkus brandą,
   kategoriją, kainą ar kitą filtrą dydžių sąrašas bei jo prieinamumas nebeatspindi
   likusio katalogo. Tai tiesiogiai prieštarauja tikslui išsaugoti facetų
   kontekstualumą.
2. **BLOKUOJA – pašalinti dydžių kiekiai.** Statinio dydžių cache payload neturi
   `count`, `CatalogSizeFacet.count` pakeistas į neprivalomą, o dydžių UI kiekio
   apskritai nerodo. Plano reikalavimas pateikti `Dydis · kiekis` ir tikslius
   kiekius neįvykdytas.
3. **BLOKUOJA – `otherSizes` priverstinai ištuštinamas.** `catalog_facets_cached()`
   kiekviename atsakyme nustato `otherSizes=[]`, o `CatalogFilters.vue` pašalino
   atskirą „Kiti dydžiai“ grupę. Be to, `catalog_size_facets_read` ima
   `sizes + other_sizes` tik tada, kai produktas neturi nė vieno
   `product_size_options` įrašo. Produktas, turintis dydžio pasirinkimų ir papildomų
   `other_sizes`, gali tas papildomas reikšmes prarasti UI. Tai pažeidžia kriterijų,
   kad nežinomos reikšmės neprarandamos.
4. **BLOKUOJA – dešimtainis kablelis sugadina filtro tokeną.** Plane numatyta
   `42,5` normalizuoti, bet `catalog_size_value_key()` kablelio nekeičia. Frontend
   kelias reikšmes saugo kableliais, o API `parseFilters()` taip pat skaido per
   kablelį, todėl `shoes:42,5` tampa dviem filtrais (`shoes:42` ir `5`).
5. **BLOKUOJA – alertai naudoja kitą klasifikaciją nei katalogas.**
   `catalog_item_matches()` grupuotą dydį tikrina baziniame
   `catalog_size_facets_read`, o katalogas naudoja
   `catalog_size_facets_read_effective`. Todėl produkto domeno override,
   konkrečios reikšmės override ir `exclude_from_size_filter` gali veikti kataloge,
   bet neveikti išsaugoto filtro alerte.
6. **BLOKUOJA – facetų cache po katalogo refresh paliekamas pasenęs.** Galutinis
   `rebuild_catalog_items_read_internal()` nebeišvalo `catalog_facets_cache` ir
   neperskaičiuoja brandų, kategorijų, medžiagų bei jų kiekių; jis tik pakeičia
   statinį `sizes` lauką jau esamuose payload. `catalog_facets_cached()` neturi TTL,
   todėl kartą sukurtas kontekstinis įrašas gali likti pasenęs neribotai.
7. **BLOKUOJA – 3 skyriaus UX faktiškai nepakeistas.** Checkbox `toggle()` vis dar
   iškart kviečia `apply()`, `updateFilters()` naudoja `router.push`, o
   `route.query` watcher kiekvieną kartą paleidžia produktų ir priverstinę facetų
   užklausą. Mobile „Rodyti N prekes“ tik uždaro drawer ir nėra draft filtrų
   patvirtinimas. Nėra debounce, stabilaus aktyvaus meniu snapshot ar pasenusių
   atsakymų apsaugos.
8. **BLOKUOJA – užklausų lenktynės liko.** `load()` neturi sekos numerio ar
   `AbortController`, todėl senesnė produktų užklausa gali perrašyti naujesnės
   rezultatą. `loadFacets()` taip pat pritaiko rezultatą nepatikrinusi, ar tai vis
   dar naujausias filtro raktas.

### Daliniai ir klaidingai užbaigtais pažymėti punktai

- **DALINAI – dydžių grupavimo UI.** Rodomos grupių sekcijos, bet ne planuotas
  desktop dviejų kolonų vaizdas; dydžių kiekiai nerodomi. Prieš grupuojant taikomas
  bendras `slice(0, 80)`, todėl ilgame sąraše vėlesnės grupės gali visai nepatekti į
  UI. Paieška tikrina etiketę, bet ne `domainLabel`.
- **DALINAI – klasifikavimo strategija.** `catalog_size_domain()` sujungia visas
  kategorijas ir produkto pavadinimą į vieną tekstą bei taiko regex eiliškumą.
  Nėra plane numatytos „giliausia kategorija → produkto tipas → dimensijos tipas →
  formatas“ prioritetų grandinės; funkcija net nepriima `product_types`.
- **DALINAI – normalizavimas.** „Vienas dydis“, `Onesize`, `OneSize`, `1SIZE` ir
  `NS` gauna vienodą rikiavimo vietą, bet lieka skirtingi `value_key`. `W × L`
  suklijuojamas į tekstinį raktą, tačiau nesaugomas struktūriškai. Dešimtainis
  kablelis nenormalizuojamas.
- **DALINAI – rikiavimas.** Yra alpha dydžių ir pirmo skaičiaus `sort_order`, bet
  nėra pilno `W × L` rikiavimo pagal liemenį, tada ilgį, bei nėra EU/UK/US sistemos
  semantikos.
- **DALINAI – rankiniai override'ai.** Lentelė ir admin UI yra, bet alertų
  predikatas jų nenaudoja. API pirmiausia išsaugo pakeitimą, tada invaliduoja
  cache; invalidavimo klaidos atveju grąžina 500, nors override jau gali būti
  įrašytas. Kitų naudotojų 24 val. browser `localStorage` cache neturi serverinio
  versijos signalo, o katalogo edge cache gali iki 5 min. rodyti seną rezultatą.
- **DALINAI – seno URL suderinamumas.** API skiria reikšmes vien pagal dvitaškio
  buvimą. Nėra domenų whitelist ar pilnos tokeno gramatikos validacijos, nėra
  realios katalogo užklausos testo ir nėra alertų regresinio testo.
- **NEPATIKRINTA – cron.** Migracijos tik atnaujina / aktyvuoja jau egzistuojantį
  `catalog-read-model-refresh` įrašą. Jei tokio `cron.job` nėra, naujas job
  nesukuriamas. Commit žinutės teiginys „Established a cron job“ neįrodytas.
- **NEPATIKRINTA – realus VPS rezultatas.** Nėra šiame audite leistinos nuotolinės
  patikros, migracijų preflight rezultato, snapshot audito, RPC p50/p95 ar
  nežinomų grupių dalies po pakeitimo.

### Patikrinta lokaliai

- Pradinio audito metu `npm run test`: **105/105 testų praėjo**; po kontekstinio
  cache pataisos: **108/108 testų praėjo**.
- `npm run typecheck`: workspace tipų patikros praėjo; Wrangler papildomai pranešė,
  kad sandbox aplinkoje negalėjo įrašyti savo log failo už workspace ribų.
- `npm run build`: API Worker dry-run ir production Nuxt build praėjo.
- Pridėtas izoliuotas PostgreSQL 17 kategorijos cache testas, tačiau dar nėra VPS
  snapshot, Vue komponento, alertų override ar E2E patikros.

### Sprendimas po audito

Commit laikomas **daliniu prototipu**, o ne užbaigtu 2 etapu. Prieš taikant į
produkciją pirmiausia reikia atkurti kontekstinius dydžių kiekius, sutvarkyti
`otherSizes` nepraradimą ir dešimtainius tokenus, suvienodinti katalogo bei alertų
predikatą, grąžinti teisingą cache invalidavimą ir tik tada vykdyti VPS snapshot
bei našumo patikrą.

### 2026-07-31 kontekstinio cache perprojektavimas

Po realaus džinsų kategorijos pavyzdžio pridėta migracija
`202607310001_restore_contextual_size_facets.sql`. Ji pakeičia klaidingą
„vienas globalus dydžių sąrašas visiems puslapiams“ modelį:

- katalogo šaknyje be filtrų leidžiama naudoti vieną statinį dydžių žodyną;
- kategorijos ar bet kurio kito filtro atveju `catalog_grouped_size_facets()`
  atrenka tik tuos produktus, kurie atitinka kategoriją, brandą, spalvą, kainą,
  medžiagą ir kitus aktyvius ne dydžio filtrus;
- dydžių sąrašas sudaromas tik iš atrinktų produktų, todėl
  `vyrams>drabužiai>džinsai` puslapyje negali atsirasti krepšių, diržų ar apyrankių
  grupė, jei toje kategorijoje nėra taip suklasifikuoto produkto;
- kiekvienas dydis vėl turi kontekstinį `count`, o UI jį rodo;
- visas facetų atsakymas saugomas `catalog_facets_cache` pagal tikslų normalizuotą
  filtro JSON. Pirma konkrečios kategorijos užklausa skaičiuoja, pakartotinės skaito
  jos cache;
- po read modelio refresh arba rankinio klasifikacijos override visi filtro cache
  įrašai išvalomi, todėl sena globali narystė negali likti kategorijos payload;
- browser cache versija pakeista į `v3`, o TTL sumažintas nuo 24 val. iki 5 min.,
  kad DB pakeitimas naudotojui neužstrigtų visai parai.

Lokaliai pridėtas migracijos kontrakto testas tikrina, kad kategorija ir kiti
filtrai realiai naudojami SQL, grąžinamas `count`, naudojamas exact cache raktas ir
refresh išvalo pasenusius įrašus. Papildomas
`supabase/tests/contextual_size_facets_test.sql` testas sėkmingai paleistas
izoliuotoje PostgreSQL 17 DB: įdėjus vieną džinsų ir vieną krepšio produktą,
džinsų kategorijos atsakymas grąžino tik `trousers:w32-l32`, `count=1`, negrąžino
`bags:one-size` ir sukūrė tikslų kategorijos cache įrašą. Tai dar nėra realios VPS
DB našumo testo pakaitalas.

#### Šios pataisos priėmimo patikra

- [x] Lokaliai paruošti kategorijos kontekstą naudojantį RPC ir exact-filter cache.
- [x] Lokaliai grąžinti kontekstinius dydžių kiekius į DB kontraktą ir UI;
  `CatalogSizeFacet.count` paliktas neprivalomas, nes nepakeistas globalus statinis
  payload istoriniuose VPS įrašuose kiekio neturi.
- [x] Sumažinti browser facetų cache TTL ir pakeisti jo versijos prefiksą.
- [x] Pridėti statinį migracijos regresinį testą, kad `p_filters` nebūtų vėl
  ignoruojamas.
- [x] Pritaikyti migraciją izoliuotoje PostgreSQL 17 DB ir elgsenos testu
  patikrinti kategorijos izoliaciją, kiekį bei cache hit įrašą.
- [x] Naudotojas pritaikė `202607310001_restore_contextual_size_facets.sql` VPS;
  migracija baigėsi be klaidų, pašalinti 7 seni facetų cache įrašai.
- [x] VPS džinsų kategorijos RPC patikra rado 1594 kategorijos produktus ir grąžino
  114 dydžių reikšmių; visų jų `domainKey` yra tik `trousers`, globalių aksesuarų,
  krepšių, diržų ar apyrankių grupių negrąžinta.
- [x] Po dydžių migracijos aptiktas kitas neatitikimas: legacy `catalog_facets()`
  pilną kategorijos kelią lygina tik su `catalog_items_read.categories`, todėl
  prekės ženklų, spalvų, medžiagų ir kiti facetai kategorijoje ištuštėja.
  `202607310002_restore_contextual_non_size_facets.sql` išlaiko
  tikslų cache/dydžių kelią, o legacy facetų skaičiavimui prideda canonical
  kategorijos pavadinimą; naudotojas ją sėkmingai pritaikė VPS (`DELETE 19`).
- [ ] Naršyklėje patvirtinti, kad po `202607310002` kategorijoje vėl rodomi ir
  pritaikomi prekės ženklo, spalvos, medžiagos bei kiti ne dydžių filtrai.
- [ ] Išmatuoti pirmos neužkešuotos kategorijos užklausos ir pakartotinio cache hit
  p50/p95; jei pirmas skaičiavimas per lėtas, pridėti populiariausių kategorijų
  prewarm, negrįžtant prie globalaus sąrašo.

VPS adresas: `169.58.26.120`, SSH naudotojas: `deploy`, PuTTY privataus rakto
failas: `C:\Users\Auris\Documents\contabo.ppk`, patvirtintas ED25519 host rakto
fingerprint: `SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q`.

VPS patikroje aptiktas dar vienas migracijų neatitikimas: statinio dydžių builderio
ir refresherio savininkas yra `supabase_admin`, o kontekstinio cache funkcijų –
`postgres`; `postgres` negali `SET ROLE supabase_admin`. Migracija pataisyta taip,
kad nekeistų `supabase_admin` valdomo globalaus builderio ir nereikalautų plėsti DB
teisių. Kategorijų dydžiai bei jų `count` kuriami atskirai, `postgres` valdomoje
kontekstinėje funkcijoje.

Pirmiausia įkelti passphrase apsaugotą `.ppk` į Pageant. Atsidariusiame lange
įvesti rakto passphrase:

```powershell
Start-Process -FilePath "C:\Program Files\PuTTY\pageant.exe" `
  -ArgumentList '"C:\Users\Auris\Documents\contabo.ppk"'
```

Tada patikrinti neinteraktyvų prisijungimą, nesiunčiant migracijos:

```powershell
& "C:\Program Files\PuTTY\plink.exe" `
  -batch `
  -agent `
  -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
  deploy@169.58.26.120 "whoami"
```

Kadangi `deploy` naudotojo `sudo` prašo slaptažodžio, SQL negalima pipe'inti per
SSH stdin. Gavus atsakymą `deploy`, pirmiausia migracijos failą nukopijuoti į VPS:

```powershell
& "C:\Program Files\PuTTY\pscp.exe" `
  -agent `
  -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
  ".\supabase\migrations\202607310001_restore_contextual_size_facets.sql" `
  deploy@169.58.26.120:/tmp/202607310001_restore_contextual_size_facets.sql
```

Tada atidaryti interaktyvią VPS sesiją:

```powershell
& "C:\Program Files\PuTTY\plink.exe" `
  -agent `
  -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
  deploy@169.58.26.120
```

VPS terminale paleisti migraciją, įvesti `deploy` naudotojo sudo slaptažodį ir tik
po sėkmingo `psql` užbaigimo pašalinti laikiną failą:

```bash
sudo docker exec -i supabase-db psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres \
  < /tmp/202607310001_restore_contextual_size_facets.sql
rm -f /tmp/202607310001_restore_contextual_size_facets.sql
exit
```

### Privalomi pataisymai prieš pakartotinį priėmimą

- [x] **LOKALIAI:** grąžinti `p_filters` naudojimą dydžių facete ir kiekvienam
  dydžiui pateikti kontekstinį `count`.
- [x] **LOKALIAI:** naudoti statinį žodyną tik nefiltruotai šakniai, o kategorijai
  ir kitiems filtrams skaičiuoti dinaminę narystę bei kiekius.
- [ ] Užtikrinti, kad `other_sizes` reikšmės neprarandamos, ir pridėti produktų su
  `product_size_options` bei `other_sizes` regresinį testą.
- [ ] Įvesti nedviprasmį URL kodavimą arba tokeno formatą, kuris palaiko `42,5`,
  bei validuoti domeną ir `value_key` atskirai.
- [ ] `catalog_item_matches()` perkelti į tą patį effective dydžių modelį, kurį
  naudoja katalogas; padengti produkto, reikšmės ir exclude override alertų testais.
- [x] **LOKALIAI:** po read modelio refresh išvalyti visus facetų cache įrašus, o
  browser TTL sumažinti iki 5 min.; VPS elgesį dar reikia patikrinti.
- [ ] Atskirtą override išsaugojimą ir cache invalidavimą padaryti idempotentišką,
  kad dalinė sėkmė nebūtų rodoma kaip neaiški 500 klaida.
- [x] Įgyvendinti draft/applied filtrus: checkbox, greiti filtrai ir slankikliai
  nebekrauna katalogo po kiekvieno pakeitimo, o pritaikomi vienu veiksmu.
- [ ] Užbaigti `router.replace`/istorijos strategiją ir užklausų atšaukimą arba seką.
- [ ] Pridėti DB/RPC integracinius, Vue komponento, alertų ir E2E testus pagal
  šiame dokumente išvardytus scenarijus.
- [x] Po vietinių testų pateiktos tikslios VPS migravimo komandos; migracijos
  vykdymą ir kategorinio RPC rezultatą patvirtino naudotojas. Bendras snapshot bei
  rollback scenarijus lieka reikalingas būsimoms platesnėms migracijoms.

## Tikslas

Padaryti katalogo rikiavimą ir filtravimą greitą bei nuspėjamą:

- LPL rikiavimo variantus pateikti natūralia tvarka – nuo mažiausios kainos į
  didžiausią;
- prie kiekvieno dydžio aiškiai parodyti, kokiai prekių grupei jis priklauso;
- leisti pažymėti kelis dydžius ar kitas reikšmes neperkraunant atidaryto filtro
  sąrašo po kiekvienos varnelės;
- išsaugoti filtrus URL, produktų skaičiaus tikslumą ir katalogo facetų
  kontekstualumą.

## Dabartinė situacija kode

- `apps/web/components/CatalogViewControls.vue` LPL rikiavimą rodo tokia tvarka:
  `source_lpl_desc`, tada `source_lpl_asc`.
- Mobiliojo katalogo pasirinkimai `apps/web/pages/index.vue` pakartoja tą pačią
  tvarką.
- `apps/web/components/CatalogFilters.vue` dydžio facetą gauna tik kaip
  `{ value, count }`, todėl vien iš reikšmės, pavyzdžiui, `42`, naudotojas negali
  atskirti batų, kelnių ar švarko dydžio.
- Pažymėjus checkbox, `toggle()` iškart kviečia `apply()`. Tai pakeičia URL, o
  `apps/web/pages/index.vue` `route.query` stebėtojas iš naujo užkrauna produktus
  ir priverstinai užklausia facetus su `{ force: true }`.
- Produkto detalių modelio `product_size_options.size_group` pavadinimas gali
  klaidinti: tai ne prekės grupė. Dabartinis parseris į šį lauką deda antrą
  dydžio dimensiją, dažniausiai kelnių ilgį `30/32/34/36` arba variantą
  `įprastas ilgis`. Prekės grupę reikia nustatyti atskirai.
- Dabartinis katalogo read modelis ir `CatalogFacets.sizes` dydžius filtruoja tik
  pagal tekstinių `sizes` masyvų persidengimą.

## 1. LPL rikiavimo variantų tvarka

### Problema

Trečias ir ketvirtas kainos rikiavimo variantai pateikti nuo didžiausios LPL
kainos į mažiausią. Įprasta paieškos eiga prasideda nuo pigiausių prekių, todėl
pirmiau turi būti rodomas didėjantis variantas.

### Sprendimas

Abiejose sąsajose sukeisti tik pasirinkimų rodymo tvarką:

1. `Paskutinė mažiausia kaina: nuo mažiausios` – `source_lpl_asc`;
2. `Paskutinė mažiausia kaina: nuo didžiausios` – `source_lpl_desc`.

API rikiavimo reikšmių ir jų semantikos keisti nereikia. Taip nebus sugadintos
išsaugotos nuorodos ar alertų filtrai.

### TODO

- [x] `CatalogViewControls.vue` perkelti `source_lpl_asc` prieš
  `source_lpl_desc`.
- [x] `pages/index.vue` mobiliajame `<select>` pakartoti tokią pačią tvarką.
- [ ] Patikrinti, kad abiejų variantų etiketės atitinka realų API rezultatą.
- [x] Pridėti regresinį testą rikiavimo pasirinkimų tvarkai ir reikšmėms.
- [ ] Patikrinti jau išsaugotą URL su `sort=source_lpl_asc` ir
  `sort=source_lpl_desc`.

### Priėmimo kriterijai

- Didėjantis LPL variantas rodomas prieš mažėjantį desktop ir mobile sąsajose.
- Pasirinkus didėjantį variantą, pirmiausia rodomos prekės su mažiausia LPL.
- Esami URL ir alertai išlaiko ankstesnę rikiavimo reikšmę.

## 2. Dydžio filtro grupavimas

### Commit'e įdiegta dalis (po audito nepriimta)

- Naujas filtro tokenas yra `domain:value_key`, pavyzdžiui,
  `shoes:42` arba `socks:39-42`.
- Senos nuorodos, pavyzdžiui, `sizes=42`, lieka priimamos kaip suderinamumo
  įvestis ir toliau naudoja seną negrupuotą paiešką.
- Dydžio facetai grupuojami pagal kategorijos kelią ir produkto pavadinimą;
  `product_size_options.size_group` naudojamas tik antrajai dimensijai.
- Neatpažinti dydžiai numatyti grupėje `Kita`, tačiau `otherSizes` sujungimo ir
  ištuštinimo logika gali dalį reikšmių prarasti.
- Automatinė klasifikacija nėra vienintelis autoritetas: rankiniai produkto
  override'ai saugomi atskiroje lentelėje ir nėra perrašomi sync metu.
- Supabase funkcija `catalog_size_classification_audit()` pateikia `Kita`
  reikšmių ir produktų skaičių. Tai kontrolinis sąrašas, iš kurio naujos
  klasifikavimo taisyklės turi būti perkeliamos į `catalog_size_domain()`.

Commit pridėjo migracijų grandinę nuo
`202607290001_group_catalog_size_facets.sql` iki
`202607300009_cache_static_size_facets.sql`. Tikslinės VPS būsenos šiame audite
tikrinti neleidžiama, todėl nėra patvirtinta nei kad visa grandinė pritaikyta, nei
kad galutinė schema ir cache veikia su realiu katalogo snapshot. `Kita` turi likti
audito eile, o ne galutine produkto grupe.

### Problema

Tas pats skaičius gali reikšti skirtingus matmenis. Pavyzdžiui, `42` gali būti
batų EU dydis, švarko dydis arba kelnių dydis. Vienos kolonos sąrašas nerodo
konteksto, o bendrinės reikšmės, tokios kaip `S`, `M`, `L`, maišomos su batų,
juosmens, apykaklės, kojinių ir aksesuarų dydžiais.

Tai ne vien pateikimo problema. Jei filtras siunčia tik `sizes=42`, dabartinis
duomenų modelis gali grąžinti visų grupių produktus su reikšme `42`. Todėl vien
vizualiai pridėta grupės kolona būtų klaidinanti, jei filtravimo užklausa ir
toliau neatskirtų grupių.

### 2026-07-29 realių VPS duomenų auditas

Auditas atliktas skaitant iš projekto `.env` nurodyto self-hosted VPS Supabase
`supabase-staging.rinkissaupigiausia.online`. Tai nėra senasis
`*.supabase.co` projektas. Analizės metu katalogo read modelyje buvo apie
48,8 tūkst. aktyvių produktų, o `product_size_options` lentelėje – apie
355 tūkst. pasirinkimų. Katalogas atnaujinamas, todėl tikslūs skaičiai tarp
užklausų gali nežymiai keistis.

Dabartinis nefiltruotas dydžių facetas grąžino:

- `881` unikalias `sizes` reikšmes;
- `48` unikalias `otherSizes` reikšmes;
- apie `187 tūkst.` produkto ir dydžio narystės atvejų;
- kelis tos pačios semantikos užrašymo variantus: `Vienas dydis`, `Onesize`,
  `OneSize`, `1SIZE` ir `NS`;
- suderinamumo modelius, pvz. `iPhone 12/12 Pro`, `iPhone 13 Pro` ir
  `iPhone 13 Pro Max`, kurie šaltinyje pateikiami dydžio laukuose. Jie nėra
  automatiškai laikomi telefono dėklais, nes produkto pavadinime gali būti
  klaidinančių žodžių, pvz. `GALAXY`.

Tai įrodo, kad vienas bendras abėcėlinis dydžių sąrašas nėra pakankamas.

#### Kojinės

Kataloge rasta apie `800` kojinių produktų ir `57–58` unikalios dydžio etiketės.
Dažniausi realūs pasirinkimai:

| Dydis | Apytikslis produktų skaičius audito metu |
|---|---:|
| `39–42` | 180–196 |
| `43–46` | 165–189 |
| `Vienas dydis` | 155–168 |
| `35–38` | 132–138 |
| `40–42` | 127–131 |
| `37–39` | 116–129 |
| `34–36` | 105–106 |
| `43–45` | 84–94 |
| `46–48` | 73–84 |
| `46–50` | 63–71 |

Taip pat yra `34–38`, `38–42`, `42–46`, `44–46`, `47–49` ir retesnių
intervalų. Kojinės privalo būti atskira grupė, o ne `Kita` ar bendri
`Drabužiai`.

`product_size_options.size_group` audituotame 100 kojinių produktų sample buvo
`null` visiems 275 dydžio pasirinkimams. Kojinių grupės iš šio lauko gauti
negalima; ją patikimai nurodo kategorijos kelias
`vyrams>drabužiai>apatiniai>kojinės` ir produkto tipas.

#### Kiti realūs dydžių domenai

| Domenas | Produktų mastas | Realūs dažni dydžiai | Svarbi semantika |
|---|---:|---|---|
| Drabužiai | apie 18 tūkst. kitų drabužių | `XS–XXXL`, `4XL–7XL` | Bendrinius raidinius dydžius UI gali rodyti kaip `Drabužiai`. |
| Marškiniai | apie 2,4 tūkst. | `XS–XXL`, `S–M`, `M–L`, taip pat `38–41` | Skaitiniai apykaklės dydžiai neturi susilieti su batais. |
| Kelnės ir džinsai | apie 5,4 tūkst. | `28 × 30`, `30 × 32`, `32 × 34`, `31–32`, `33`, `34` | Reikia atskirti liemenį ir ilgį. |
| Kostiumai ir švarkai | apie 580 | `44–58`, ilgieji `98/102/106`, kai kurios `W × L` reikšmės | Atskira skaitinių dydžių sistema. |
| Batai | apie 7,4 tūkst. | EU `36–48`, pusiniai ir intervaliniai dydžiai | `42` yra dažna kolizija su kitomis grupėmis. |
| Apatiniai be kojinių | apie 1,4 tūkst. | `XS–XXL` | Gali būti po `Drabužiai`, bet domenas turi likti žinomas. |
| Maudymosi drabužiai | apie 490 | `XS–XXXL` | Raidinis dydis, atskiras produkto domenas. |
| Kojinės | apie 800 | `35–38`, `39–42`, `43–46`, `46–50` | Būtina atskira grupė. |
| Diržai | apie 890 | `75–120`, dažniausiai `85/90/95/100/105` | Reikšmė yra ilgis centimetrais. |
| Kepurės ir skrybėlės | apie 2,2 tūkst. | `Vienas dydis`, `55–56`, `56–57`, `60–61` | Skaičiai reiškia galvos apimtį centimetrais. |
| Pirštinės | kelios dešimtys | `S`, `M`, `L`, `S–M`, `L–XL` | Raidė sutampa su drabužiais, bet matuojama plaštaka. |
| Akiniai | apie 1,2 tūkst. | `Vienas dydis`, `Onesize`, `50–60` | Skaičius paprastai yra rėmelio / lęšio dydis. |
| Juvelyrika | šimtai | žiedams `50–70`, apyrankėms `19/21/23` | Reikia skaidyti pagal produkto tipą. |
| Krepšiai ir kuprinės | apie 2,2 tūkst. | beveik visada `Vienas dydis` | Sinonimus reikia normalizuoti. |
| Telefono dėklai | keli dabartiniame kataloge | konkretūs `iPhone` modeliai | Tai suderinamumo modelis, ne kūno dydis. |

Sportas negali būti viena dydžio grupė. Kategorijos šaka `Sportas` turi ir
drabužių, ir batų, ir pirštinių, todėl po jos dar reikia naudoti giliausią
kategoriją arba produkto tipą.

#### Įrodytos reikšmių kolizijos

- `42` audito metu turėjo apie 4,4 tūkst. batų, šimtus sporto šakos produktų,
  dešimtis marškinių ir kelnių bei kostiumų/švarkų atvejų.
- `38` buvo dažnas ir batams, ir kelnėms, taip pat pasitaikė marškiniams.
- `46`, `48` ir `50` sutapo tarp batų, kostiumų/švarkų ir kelnių.
- `35–38` daugiausia reiškė kojines, bet pasitaikė ir kelnių bei pavieniuose
  batų produktuose.
- `S`, `M`, `L` ir `XL` naudojami drabužiams, apatiniams, maudymosi drabužiams,
  pirštinėms, kojinėms ir pavieniams aksesuarams.
- `Vienas dydis` naudojamas krepšiams, kepurėms, akiniams, juvelyrikai,
  kaklaraiščiams, piniginėms, kojinėms ir kitoms grupėms.

### Svarbi modelio korekcija: dvi skirtingos „grupės“

Reikia atskirti du nesusijusius laukus:

1. **Dydžio domenas (`size_domain`)** – `clothing`, `socks`, `shoes`,
   `trousers`, `suitwear`, `belts`, `headwear` ir panašiai. Jis paaiškina,
   kokiai prekių ir matavimo grupei priklauso dydis.
2. **Antroji dimensija (`second_dimension`)** – kelnių ilgis `30/32/34/36`,
   `trumpas`, `įprastas ilgis`, `ilgas`, batų plotis ir panašiai.

Dabartinis DB laukas `product_size_options.size_group` faktiškai yra antroji
dimensija. Parserio `extractSizeGroup()`:

- `twoDimension` atveju saugo `secondDimension`;
- `pants` atveju saugo `length`;
- `singleDimension` ir `oneDimension` atveju grąžina `null`.

Audituotame sample `size_group` buvo `null` 100 % kojinių, marškinių, apatinių,
diržų, kepurių, pirštinių, akinių, juvelyrikos ir krepšių pasirinkimų. Kelnių
sample jis dažniausiai turėjo ilgius `30/32/34/36`. Todėl šio lauko negalima
pervadinti UI į `Prekių grupė` ar naudoti kaip `size_domain`.

### Siūlomas dviejų kolonų vaizdas

Filtro eilutė turi turėti:

| Grupė | Dydis ir kiekis |
|---|---|
| Drabužiai | S · 124 |
| Kelnės ir džinsai | W32 / L32 · 48 |
| Švarkai ir kostiumai | 50 · 31 |
| Marškiniai | Apykaklė 41–42 · 17 |
| Batai | EU 42 · 86 |
| Kojinės | 39–42 · 190 |
| Diržai | 95 cm · 12 |
| Kepurės | 56–57 cm · 18 |
| Akiniai | Rėmelis 55 · 9 |

Mobile sąsajoje galima naudoti tą pačią informaciją ne kaip ankštą lentelę, o
kaip grupės antraštę ir po ja esančius dydžius. Ekrano skaitytuvui prie checkbox
vis tiek turi būti pateiktas pilnas pavadinimas, pavyzdžiui, `Batai, EU 42`.

### Rekomenduojamos dydžių grupės

| Stabilus `size_domain` | Rodomas pavadinimas | Pavyzdžiai iš VPS |
|---|---|---|
| `clothing` | Drabužiai | XXS–7XL; bendriniai raidiniai dydžiai |
| `shirts` | Marškiniai | S–XXL ir apykaklė 38–46 |
| `trousers` | Kelnės ir džinsai | W28–W40, L30–L36, W32/L32 |
| `suitwear` | Kostiumai ir švarkai | EU 44–58, ilgieji 98/102/106 |
| `underwear` | Apatiniai | XS–XXL |
| `swimwear` | Maudymosi drabužiai | XS–XXXL |
| `socks` | Kojinės | 35–38, 39–42, 43–46, 46–50 |
| `shoes` | Batai | EU 36–48 ir pusiniai dydžiai |
| `belts` | Diržai | 75–120 cm |
| `headwear` | Kepurės ir skrybėlės | vienas dydis arba 53–64 cm |
| `gloves` | Pirštinės | S–XL, S–M, L–XL |
| `eyewear` | Akiniai | vienas dydis arba rėmelio dydis 50–60 |
| `rings` | Žiedai | 50–70 |
| `bracelets` | Apyrankės | 19, 21, 23 cm |
| `bags` | Krepšiai ir kuprinės | vienas dydis |
| `wallets` | Piniginės ir kosmetinės | dažniausiai vienas dydis |
| `accessories` | Kiti aksesuarai | vienas dydis arba specialus pasirinkimas |
| `other` | Kita | tik neatpažintos ir audituotinos reikšmės |

Bendriniai `S–XXL` dydžiai turi būti rodomi kaip `Drabužiai`, kaip ir numatyta
pradiniame poreikyje, kai produktas priklauso įprastiems drabužiams. Aiški
giliausia kategorija turi pirmenybę: pirštinių `M` yra `Pirštinės`, o ne
`Drabužiai`; kojinių `39–42` yra `Kojinės`, o ne `Batai`.

### Rekomenduojamas duomenų modelis

Tikslinis sprendimas – katalogo read modelyje turėti normalizuotą sudėtinę dydžio
reikšmę, o ne grupę spėti tik naršyklėje:

```text
product_id
size_domain      clothing | trousers | socks | shoes | belts | ...
domain_label     Drabužiai | Kelnės ir džinsai | Kojinės | ...
value_key        normalizuota reikšmė, pvz. eu-42 arba w32-l32
display_label    naudotojui rodoma reikšmė, pvz. EU 42 arba W32 / L32
first_dimension  pvz. W32; nebūtina vienmačiams dydžiams
second_dimension pvz. L32; dabartinio size_group aiškesnė semantika
unit             eu | uk | us | alpha | cm | waist_length | device_model
sort_order       skaitinei, o ne abėcėlinei tvarkai
```

URL ir API reikšmė turi būti nedviprasmiška, pavyzdžiui,
`sizes=shoes:eu-42,socks:39-42,clothing:l`. Seną negrupuotą `sizes=42` formatą
pereinamuoju laikotarpiu galima priimti kaip suderinamumo įvestį, tačiau nauja UI
jo neturi generuoti.

Grupę verta nustatyti tokia prioritetų tvarka:

1. giliausias autoritetingas produkto kategorijos kelias;
2. produkto tipas, ypač mišriose šakose, tokiose kaip `Sportas`, `Juvelyrika`
   arba netiksliai suklasifikuoti telefono dėklai;
3. šaltinio dydžio dimensijos tipas ir matavimo vienetas;
4. deterministinės reikšmės formato taisyklės tik kaip pagalbinis signalas;
5. `other`, jei klasifikacija vis dar nepatikima.

Nerekomenduojama dydžio grupę nustatyti tik pagal tekstą: `42`, `M` ar `95`
neturi pakankamai informacijos be produkto kategorijos arba šaltinio grupės.
Taip pat negalima naudoti dabartinio `product_size_options.size_group`, nes jis
reiškia antrą dydžio dimensiją, o ne produkto domeną.

### Normalizavimo taisyklės

- `Vienas dydis`, `Onesize`, `OneSize`, `1SIZE` ir `NS` normalizuoti į vieną
  `value_key=one-size`, išlaikant originalią etiketę auditui.
- Lietuvišką dešimtainį kablelį ir tašką normalizuoti, bet UI rodyti lietuviškai,
  pavyzdžiui, `42,5`.
- Ženklus `x`, `×`, tarpus ir užrašus `Ilgis 32` normalizuoti į struktūrines
  dimensijas, o ne laikyti skirtingomis reikšmėmis.
- Kojinių intervalų nesulieti: `39–42` nėra tas pats kaip `40–42`.
- Diržams, kepurėms ir apyrankėms pridėti `cm`, kai vienetą patvirtina domenas.
- Batų `EU`, `UK` ir `US` dydžius laikyti atskiromis sistemomis. Jei šaltinis
  sistemos neduoda, žymėti `unknown`, o ne automatiškai vadinti `EU`.
- `size_domain` turi būti produkto ir dydžio pasirinkimo savybė read modelyje;
  jo negalima apskaičiuoti tik frontend komponento viduje.

### TODO

- [x] Patvirtinti, kad naudojamas self-hosted VPS Supabase, o ne senas hosted
  Supabase projektas.
- [x] Surinkti pirmą realių dydžių, kategorijų, `otherSizes` ir
  `product_size_options.size_group` auditą.
- [x] Nustatyti, kad dabartinis `size_group` reiškia antrą dimensiją, o ne
  produkto dydžio domeną.
- [ ] Auditą paversti pakartotinai paleidžiama diagnostine SQL/RPC su vieno
  katalogo versijos snapshot, kad skaičiai nekistų analizės viduryje.
- [ ] Aprašyti kategorijų ir produkto tipų susiejimą su stabiliais
  `size_domain`.
- [ ] Atskirai aprašyti mišrios `Sportas` šakos klasifikavimą į drabužius,
  batus, pirštines ir kitus domenus.
- [ ] Juvelyriką išskaidyti bent į žiedus, apyrankes, grandinėles ir laikrodžius.
- [x] Pašalinti telefono dėklų klasifikavimą pagal `iPhone|iPad|Galaxy|Pixel`;
  tokie žodžiai gali būti prekės pavadinimo dalis ir sukelti klaidingą grupę.
- [ ] Priimti sprendimą dėl fizinio `size_group` pervadinimo į
  `second_dimension` arba aiškaus alias read modelyje.
- [ ] Susitarti dėl URL/API formato ir seno `sizes` formato suderinamumo.
- [ ] **DALINAI:** sukurtas katalogo dydžių read modelis, bet neužbaigtas
  normalizavimas (`42,5`, vieno dydžio sinonimai, struktūrinis `W × L`) ir
  `otherSizes` nepraradimas.
- [ ] **DALINAI:** `domainKey`, `domainLabel`, `value`, `label` bei `sortOrder`
  įtraukti, bet galutinis statinis payload nebeturi `count`, o tipe jis padarytas
  neprivalomas.
- [ ] **DALINAI:** katalogo API naudoja `size_domain + value_key`, bet alertų
  `catalog_item_matches()` vis dar tikrina bazinį, override'ų nepaisantį modelį.
- [ ] `CatalogFilters.vue` desktop variante sukurti dviejų kolonų dydžių vaizdą.
- [ ] **DALINAI:** mobile variante yra grupių sekcijos, tačiau naudojamas bendras
  pirmų 80 reikšmių limitas, nėra kiekių ir nėra atskiro mobile elgesio testo.
- [ ] Bendrinius `S–XXL` rodyti grupėje `Drabužiai`, jei nėra tikslesnės šaltinio
  grupės.
- [ ] Pridėti atskirą `Kojinės` grupę ir padengti dažniausius realius intervalus.
- [ ] Normalizuoti penkis aptiktus „vieno dydžio“ sinonimus.
- [ ] Dimensinius dydžius `W × L` saugoti struktūriškai ir rikiuoti pagal liemenį,
  tada pagal ilgį.
- [ ] **DALINAI:** aktyvus dydžio chip rodo grupę tik tada, kai tokenas dar yra
  dabartiniame faceto payload; kitu atveju rodomas techninis tokenas.
- [ ] **DALINAI:** alpha dydžiai ir pirmas skaičius rikiuojami, bet `W × L`,
  dešimtainiai dydžiai bei matavimo sistemos pagal planą nesurikiuotos.
- [ ] Pridėti DB/API testus, įrodančius, kad `Batai · 42` negrąžina
  `Švarkai · 42`.
- [ ] Pridėti DB/API testus, įrodančius, kad `Kojinės · 39–42` negrąžina kitos
  grupės produkto vien dėl etiketės sutapimo.
- [x] Pridėti nežinomų grupių skaitiklį arba auditą, kad `other` netaptų
  nuolatine duomenų šiukšliadėže.
- [ ] Paleisti `catalog_size_classification_audit()` su vienu katalogo versijos
  snapshot ir susidaryti `Kita` reikšmių klasifikavimo eilę.
- [ ] Perkelti pasikartojančias `Kita` reikšmes į konkrečius domenus, papildant
  `catalog_size_domain()` taisykles, ir pakartoti auditą.
- [ ] **DALINAI:** pridėtas produkto ir konkrečių dydžių override sluoksnis bei
  Debug UI, bet jo nepaiso alertai, o cache invalidavimo klaida gali būti grąžinta
  jau po sėkmingo DB įrašo.
- [ ] Atskiriems suderinamumo modeliams nuspręsti, ar juos ateityje rodyti
  atskirame `Suderinamumas` facete, o ne dydžių filtre.

### Priėmimo kriterijai

- Kiekvienas dydis sąsajoje turi aiškiai matomą prekių grupę.
- Vienodos etiketės skirtingose grupėse yra atskiri filtro pasirinkimai.
- Pasirinkus `Batai · EU 42`, nerodomi vien dėl skaičiaus sutapimo atrinkti
  švarkai ar kelnės.
- Pasirinkus `Kojinės · 39–42`, grąžinamos tik kojinės su šiuo intervalu.
- Kojinių dydžiai nėra rodomi kaip batai, drabužiai ar `Kita`.
- `size_group=32` interpretuojamas kaip antroji dimensija / ilgis, o ne produkto
  grupė.
- Grupės ir dydžiai rikiuojami logiškai, o ne vien abėcėlės tvarka.
- Nežinomos reikšmės neprarandamos ir rodomos grupėje `Kita`.

## 3. Kelių filtrų pasirinkimas be filtro sąrašo persikrovimo

### Problema

Kiekviena varnelė šiuo metu:

1. iškart išsiunčia `update:modelValue`;
2. kviečia `router.push`;
3. suaktyvina `route.query` stebėtoją;
4. iš naujo užkrauna produktus;
5. priverstinai iš naujo užklausia ir pakeičia facetus.

Dėl to atidarytas sąrašas keičia dydį, reikšmės gali persirikiuoti ar dingti, o
kelių dydžių pasirinkimas reikalauja laukti po kiekvieno paspaudimo.
`router.push` taip pat gali sukurti atskirą naršyklės istorijos įrašą kiekvienai
varnelei.

### Rekomenduojama sąveika

Naudoti du atskirus būsenos sluoksnius:

- `draftFilters` – tai, ką naudotojas šiuo metu žymi atidarytame filtre;
- `appliedFilters` – filtrai, pagal kuriuos užkraunami produktai ir kuriami URL
  bei alertai.

Pažymėjus varnelę:

- checkbox būsena turi pasikeisti iškart;
- produktų užklausa gali būti paleista po trumpo 150–250 ms debounce, kad
  katalogas reaguotų gyvai;
- atidaryto filtro `items` sąrašas turi likti užfiksuotas iki filtro uždarymo arba
  `Taikyti` paspaudimo;
- nauji facetų duomenys neturi perrašyti aktyvaus meniu, kol naudotojas jame
  renkasi;
- uždarius meniu facetai vieną kartą sutikrinami su galutiniu filtru;
- pažymėtos reikšmės visada išlieka matomos, net jei naujame atsakyme jų kiekis
  tampa `0`.

Desktop variante verta pridėti aiškų mygtuką `Taikyti` ir tekstą, pavyzdžiui,
`Rodyti 126 prekes`. Mobile variante toks apatinis mygtukas jau yra, todėl jį
reikia padaryti tikru visų draft filtrų patvirtinimu, o ne vien drawer uždarymu.

Jei norima išsaugoti visiškai momentinį produktų filtravimą, URL naujinimui
geriau naudoti `router.replace`, o vieną istorijos įrašą sukurti tik užbaigus
sąveiką. Tai apsaugo naršyklės `Atgal` veiksmą nuo dešimčių tarpinių checkbox
būsenų.

### Užklausų ir lenktynių valdymas

- Produktų ir facetų užklausos turi turėti atskiras būsenas.
- Senesnio atsakymo negalima pritaikyti, jei po jo jau buvo išsiųsta naujesnė
  užklausa. Galima naudoti užklausos sekos numerį arba `AbortController`.
- Keisdami filtrus neturime išvalyti jau rodomų produktų; pakanka uždėti
  subtilią `Atnaujinamos prekės…` būseną.
- Facetų cache raktas turi būti sudarytas iš patvirtintų filtrų. Aktyvaus meniu
  snapshot yra trumpalaikė UI būsena ir neturi būti įrašomas kaip atskiras
  ilgalaikis cache.
- Faceto kiekiai aktyviame meniu gali trumpam rodyti ankstesnę būseną. Tai
  priimtinas kompromisas, jei sąrašas stabilus ir galutinis rezultatas po
  `Taikyti` yra tikslus.

### TODO

- [x] `CatalogFilters.vue` atskirti draft ir patvirtintą filtro būseną.
- [x] Nustoti kviesti pilną `apply()` po kiekvieno grupės checkbox paspaudimo.
- [x] Pridėti `Taikyti filtrus` veiksmą desktop filtro meniu ir bendroje juodraščio juostoje.
- [x] Mobile apatinį mygtuką susieti su draft filtrų patvirtinimu; uždarymas be
  patvirtinimo atmeta juodraštį.
- [ ] Aktyviam filtro meniu išsaugoti stabilų facetų elementų snapshot.
- [ ] Atnaujintame facetų atsakyme visada išlaikyti pasirinktas reikšmes.
- [ ] Produktų gyvam atnaujinimui pridėti 150–250 ms debounce.
- [ ] Tarpiniams URL pakeitimams naudoti `router.replace`; galutinio istorijos
  įrašo elgesį patvirtinti UX testu.
- [ ] Pašalinti besąlyginį `loadFacets(..., { force: true })` ten, kur cache arba
  jau vykstanti užklausa gali būti saugiai panaudota.
- [ ] Pridėti užklausos sekos numerį arba atšaukimą, kad senas atsakymas
  neperrašytų naujesnio.
- [ ] Atskirti `productsLoading` ir `facetsLoading`, kad produkto atnaujinimas
  neužblokuotų filtro žymėjimo.
- [ ] Pridėti komponento testą: greitai pažymėti tris dydžius ir patikrinti, kad
  visi trys lieka pažymėti bei matomi.
- [ ] Pridėti E2E testą desktop ir mobile sąsajoms.
- [ ] Patikrinti klaviatūros valdymą, `Escape`, fokusą ir ekrano skaitytuvo
  pranešimus apie atnaujintą produktų skaičių.

### Priėmimo kriterijai

- Naudotojas gali greitai pažymėti bent penkis dydžius be sąrašo užsidarymo,
  persirikiavimo ar pažymėtų reikšmių dingimo.
- Produktai atsinaujina neblokuodami kito pasirinkimo.
- Viena pasenusi užklausa negali grąžinti filtro į ankstesnę būseną.
- Po patvirtinimo URL, aktyvūs chips, produktų rezultatai ir alertui perduodami
  filtrai sutampa.
- Naršyklės istorija neužteršiama atskiru įrašu po kiekvienos varnelės.

## Įgyvendinimo etapai

### 1 etapas – greitos ir saugios UX pataisos

- [x] Sukeisti LPL rikiavimo pasirinkimus desktop ir mobile sąsajose.
- [ ] Stabilizuoti atidaryto filtro sąrašą.
- [x] Įdiegti draft/patvirtintų filtrų būseną ir realų `Taikyti` veiksmą.
- [ ] Apsaugoti sąsają nuo pasenusių užklausų atsakymų.
- [x] Padengti kelių checkbox juodraščio palyginimą ir pritaikymą testais.

### 2 etapas – teisingas dydžių modelis

- [x] Atlikti pradinį realių dydžių, kategorijų ir `size_group` auditą VPS.
- [ ] **DALINAI:** grupių žodynas įrašytas, bet normalizavimo taisyklės
  neįgyvendintos pilnai.
- [ ] **DALINAI:** DB/read modelio migracijos ir indeksai pridėti, bet galutinė
  migracija panaikina kontekstinius dydžių kiekius ir palieka pasenusį facetų cache.
- [x] Nauja migracija grąžina kontekstinį `count`; VPS patikroje visi 114 džinsų
  dydžių priklausė tik `trousers` domenui. TypeScript `count` neprivalomas tik dėl
  istorinio globalaus statinio payload suderinamumo.
- [ ] Katalogo ir alertų dydžių predikatai tebėra išsiskyrę.
- [ ] **DALINAI:** dydžiai rodomi grupėmis, bet nėra pilno dviejų kolonų vaizdo,
  kiekių ir visų grupių pateikimo garantijos.
- [ ] **DALINAI:** legacy reikšmės priimamos, bet nėra tikro katalogo ir alertų
  regresinių testų; dvitaškis bei dešimtainis kablelis apdorojami nesaugiai.
- [ ] Pritaikyti migraciją tiksliniam VPS ir atlikti `Kita` klasifikacijos auditą.

### 3 etapas – kokybės ir našumo patikra

- [ ] Išmatuoti užklausų skaičių greitai pažymint penkis filtrus prieš ir po
  pakeitimo.
- [ ] Patikrinti facetų RPC p50/p95 su nauju dydžių modeliu.
- [ ] Patikrinti desktop, siaurą ekraną ir mobile drawer.
- [ ] Patikrinti naršymą klaviatūra bei ekrano skaitytuvą.
- [ ] Produkcijoje patikrinti, kad nežinomų dydžio grupių dalis yra priimtina.

## Testavimo scenarijai

1. Atidaryti `Dydis`, greitai pažymėti `S`, `M`, `L` ir įsitikinti, kad meniu
   nepersikrauna.
2. Pažymėti dydį, kurio kiekis po kitų filtrų tampa `0`, ir įsitikinti, kad jis
   lieka matomas bei gali būti atžymėtas.
3. Pasirinkti `Batai · EU 42` ir patikrinti, kad rezultatuose nėra vien dėl `42`
   sutapimo atrinktų švarkų.
4. Pasirinkti `Drabužiai · M` ir kitą grupę vienu metu; pagal dabartinę katalogo
   semantiką tos pačios grupės reikšmės turi veikti su `OR`, skirtingos filtrų
   grupės – su `AND`.
5. Greitai pažymėti ir atžymėti kelias reikšmes esant lėtam tinklui; paskutinė
   naudotojo būsena turi laimėti.
6. Po `Taikyti` perkrauti puslapį ir patikrinti, kad būsena atkuriama iš URL.
7. Sukurti filtro alertą ir patikrinti, kad jame išsaugomos grupuotos dydžių
   reikšmės.
8. Patikrinti LPL didėjantį ir mažėjantį rikiavimą su `null` LPL reikšmėmis.

## Sąmoningai nedaroma

- Nekeičiama `source_lpl_asc` ir `source_lpl_desc` API reikšmių semantika.
- Dydžių grupė nebus patikimai nustatoma vien iš neapibrėžtos etiketės.
- Facetų kiekiai neturi būti perskaičiuojami po kiekvieno klavišo paspaudimo
  paieškos laukelyje.
- Nebus slepiamos neatpažintos dydžių reikšmės; jos laikinai pateks į `Kita`.

## Uždarymas

- [ ] Visi trijų problemų priėmimo kriterijai įvykdyti.
- [ ] Dokumentacijos išvados perkeltos į nuolatinę techninę dokumentaciją.
- [ ] Baigta – galima ištrinti.

## 2026-10-07 atnaujinimas (09:31 Europe/Vilnius)

- VPS per patvirtintą tunelį ir `codex_reader` skaityta tik `BEGIN READ ONLY` transakcijose, užbaigtose `ROLLBACK`. Du natūralūs ciklai baigėsi švariai: 06:10:00.042–06:14:18.637 UTC, **258 595 ms**, `2290/2290`; 06:20:00.063–06:24:23.500 UTC, **263 435 ms**, `2291/2291`. Po anksčiau fiksuoto 300 s timeout tai du geri ciklai, bet priėmimui reikia trijų iš eilės. Per-ciklo cache narystės lygybė dar nepatvirtinta.
- Timeout riba apima nuoseklias MV ir cache fazes: maždaug 112 s `effective_size_membership` fazė pati savaime nepaaiškina ankstesnio 300 s limito; ankstesnės fazės sunaudojo likusią biudžeto dalį. Planner-only `EXPLAIN` įverčiai nesutampa su statistika (`catalog_items_read` ~391k/~104k, size facets ~63k/~366k, facet values ~12,2M/~2,33M). Tai galimo pasenusių ar netikslių planavimo įverčių indėlio įrodymas, ne vienintelės priežasties įrodymas. Per-ciklo CPU/disko ir dalis query/cron metrikų neprieinamos.
- **Paruošta lokaliai:** [ANALYZE migracija](../../supabase/migrations/20261007100000_analyze_catalog_refresh_materialized_views.sql) ir [atskiras skaitymo režimo patikros SQL](VERIFY_20261007100000_analyze_catalog_refresh_materialized_views.sql). Migracijoje yra gyvos funkcijos MD5 preflight `9550e4f8105b660870670d3493b01b2b`; ji skirta pagerinti planavimo statistiką, ne didinti timeout. **VPS nepritaikyta** — naudotojas ją vykdo SQL Editor, po to reikalinga read-only patikra ir trys natūralūs ciklai. Migracija kol kas neįrodo timeout priežasties pašalinimo.
- **Frontend paruošta lokaliai:** cache, invalidavimo ir draft regresijos įtrauktos; 29 failai / 175 testai, tipų patikra ir web build praėjo, `git diff --check` švarus, nepriklausomo review reikšmingų likusių defektų nerado. **Produkcijoje tikrinta dalinai:** autentifikuoto desktop UI `42,5`, keli pasirinkimai apply/cancel, Back/Forward, reload, Escape/meniu; pirmas facetų prašymas nepavyko ir retry klaidą pašalino. Bundle `9C2E2YzC.js` nesutampa su lokaliu build, o revision žymeklio nėra. API HTTP kodai/trukmės, mobile, trijų skirtukų invalidavimas ir dalis tinklo klaidų scenarijų liko nepatikrinti. **Nedeployinta**; nėra patvirtinto deploy/rollback revision.
- „Galaxy“ klasifikacijos audite 15 realių `Galaxy 8` produktų buvo batai, effective tokenai `shoes:*`; `device_cases.*` nerasta. Ši imtis patvirtina tikrinamą klasifikaciją, ne visas filtrų semantikas.


## 2026-10-07 09:55 Europe/Vilnius: SQL patikra ir 2–3 etapų lokali pažanga

Naudotojas pranešė, kad paleido `ANALYZE` migraciją. Read-only patikra per autorizuotą tunelį patvirtino gyvos funkcijos apibrėžimo/order ir invalidation guard'us; SQL Editor „Success“ išvestis negauta, o `last_analyze` bei autoanalyze datos nepatvirtina migracijos efekto. `2292/2292 clean` ciklas (255,963 ms) neįskaitomas kaip po-migracijos priėmimas. Vietinė `other_sizes` dešimtainio kablelio API regresija pataisyta, pridėtos alert payload regresijos. `npm test` 182/182, typecheck, web build, `git diff --check` ir nepriklausoma peržiūra praėjo. Naudotojo Pages auto-update commit `b515758` buvo ankstesnis už naują vietinę `other_sizes` pataisą ir alert payload testų refaktoriavimą; šie pakeitimai necommitinti ir nepatenka į tą diegimą, nebent bus atskirai commitinti. Produkcinis bundle/revision ir API priėmimas dar nepatvirtinti. Išlieka 20/100; 1–4 etapai nepriimti.

## 2026-10-07 10:02 Europe/Vilnius: pirmas po-migracijos refresh kandidatas ir UI tęsinys

Natūralus `2293/2293 clean` ciklas truko **251,669 ms** (06:55:00.025–06:59:11.694 UTC), `last_error=NULL`. Abiejų vaizdų `last_analyze` atnaujintas ciklo metu: items 06:55:18.514 UTC, size facets 06:57:06.800 UTC. Tai pirmas po-migracijos kandidatas, dar ne priėmimas: reikia dar dviejų iš eilės clean ciklų <300 s. Root facetų cache turi vieną `{}` eilutę, tačiau `catalog_static_size_facets_cache` neprieinamas skaityti, todėl pilna cache/narystės lygybė nepatvirtinta.

Produkcijos UI patikroje `42,5` rodė grupes „Kita“ ir „Batai“, be matomos dėklų grupės; Escape uždarė meniu palikdamas juodraščio pasirinkimą, o „Atšaukti“ jį išvalė. „Batai“ kategorijoje buvo 8 808 produktai, patikrinti batų pavyzdžiai; grįžus į šaknį rodyta 103 791. Produkcinio bundle commit vis dar nenustatytas. Naudotojo Pages auto-update commit `b515758` ankstesnis už vietines `other_sizes` ir alert payload pataisas; jos necommitintos ir nėra to commit deploy dalis, nebent bus atskirai commitintos.

Bendra pažanga lieka **20/100**. [Einamasis planas](FILTRAVIMO_PATOBULINIMU_PLANAS.md) ir [eigos įrašas](ATNAUJINIMO_EIGA_2026-10-05.md) atnaujinti; API laikai, pilna cache lygybė ir likęs produkcinis UI priėmimas atviri.

## 2026-10-07 10:23 Europe/Vilnius: antras po-migracijos natūralaus ciklo kandidatas

Antras iš trijų ciklų: natūralus `2295/2295` refresh pradėtas 07:05:00.024519 UTC, baigtas 07:09:19.784814 UTC per **259,760 ms**; būsena `refreshed`, vėliau skaityta `clean`, `last_error=NULL`. `last_analyze` atnaujintas ciklo metu: items 07:05:17.783985 UTC, size facets 07:07:12.127877 UTC. Kartu su `2293` tai **2/3** priėmimo ciklų. 07:22:50 UTC būsena liko `2295/2295 clean`; trečios naujos natūralios versijos dar nebuvo. Reikia dar vieno iš eilės clean ciklo <300 s ir cache narystės lygybės patikros; `catalog_static_size_facets_cache` nepasiekiama `codex_reader` SELECT teisei.

Lieka atviri produkcinio API atsakymų laikai/statusai, mobile ir kelių skirtukų UI bandymai bei bundle/revision identifikacija. `b515758` neapima vėliau atsiradusių necommitintų `other_sizes` API bei alert payload pakeitimų. Bendra pažanga lieka **20/100**; etapai 1–4 nepriimti.

## 2026-10-07 12:22 Europe/Vilnius: cache pariteto patikra ir metrikų ribos

- Read-only patikroje 09:17–09:22 UTC `codex_reader` turėjo `SELECT` teisę į `catalog_static_size_facets_cache`. Ciklas `2303/2303 clean` truko **274,426 ms** (09:05:00.029–09:09:34.455 UTC); 2434 agreguoti facetai tiksliai sutapo JSON, narystė turėjo **374466** eilučių. Šio ciklo cache paritetas patvirtintas.
- `pg_stat_io` skaitomas; backend tipo kaupiamoji bazė užfiksuota 09:22:12.941386 UTC, bet `track_io_timing=off`, tad per-refresh diskas ir hosto CPU neišmatuoti. `pg_stat_statements` egzistuoja `extensions` schemoje, tačiau `codex_reader` neturi schemos prieigos. Cloud aplinkoje resursų tendencijoms naudoti Supabase Dashboard; savame VPS rinkti hosto OS `vmstat`/`iostat`/`pidstat` skaitiklius. Nuolatinis monitor agentas neįdiegtas.
- Trūksta tarpinių ciklų istorijos, todėl trijų iš eilės priėmimo patvirtinti negalima. Bendra pažanga lieka **20/100**.
