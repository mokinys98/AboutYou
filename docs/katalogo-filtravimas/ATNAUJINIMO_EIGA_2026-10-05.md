# Katalogo filtravimo darbai 2026-10-05

## Sprendimas pagal 2026-10-04 matavimus

Šešios skirtingos API cache miss / hit poros buvo sėkmingos, tačiau jų neužtenka
patikimam p95. Pilnas `catalog_effective_size_membership_read` atnaujinimas yra
susijęs su `AccessExclusiveLock`; vakar per tokį ciklą stebėtas produktų API
HTTP 500. Vienas ciklas trunka apie keturias minutes iš penkių minučių
intervalo. Todėl pirmiausia tikrinamas ir mažinamas refresh poveikis skaitymui,
o pilnas API matavimas atliekamas po to.

## Paruošta lokaliai

- [Prieš pakeitimą vykdoma skaitymo režimo diagnostika](../../supabase/tests/diagnose_nonblocking_refresh_preflight_read_only.sql)
  patikrina dabartinę versiją, funkcijos savininką, pilną refresh, greitą
  statinių dydžių kelią, unikalaus indekso tinkamumą ir momentinį užraktą.
- [Migracija](../../supabase/migrations/20261005090000_nonblocking_effective_size_refresh.sql)
  keičia tik effective dydžių vaizdo atnaujinimą į `CONCURRENTLY`, išsaugo
  vakarykštį statinio dydžių skaičiavimo optimizavimą ir fazių klaidų žymas.
  Ji nepradeda refresh. Kitas suplanuotas ciklas parodys, ar visas kelias
  telpa į 300 s ribą. Naujas funkcijos apibrėžimas jau matomas VPS per
  skaitymo tunelį; atskira SQL Editor „Success“ išvestis dar negauta.
- [Patikra po migracijos](../../supabase/tests/verify_nonblocking_effective_size_refresh_read_only.sql)
  tikrina funkciją, indeksą, katalogo versijas, paskutinio ciklo trukmę ir
  momentinį `AccessExclusiveLock`. [Statinio cache lygybės patikra](../../supabase/tests/verify_catalog_static_size_reuse_read_only.sql)
  papildomai palygina cache turinį su paruošta naryste.
- API matuoklis turi `--start-index` vienos ar dviejų porų segmentams per
  skirtingus stabilius langus. Kiekviena pora įrašo katalogo versiją prieš ir
  po užklausų; versijai pasikeitus ji nelaikoma galiojančia.

## Šiandienos patikros būsena

Iš pradžių vietinis `127.0.0.1:15432` tunelio portas nepriėmė TCP ryšio.
Naudotojui jį atkūrus, 06:28 UTC `codex_reader` skaitymo transakcija patvirtino:
`concurrent_refresh_installed = true`, `fast_static_dictionary_retained = true`,
`slow_static_rebuild_absent = true`, `concurrent_index_ready = true`. Tuo metu
vyko 2105 versijos ciklas: ant effective dydžių vaizdo buvo suteiktas
`ExclusiveLock`, bet ne `AccessExclusiveLock`. Naudotojo po migracijos paleistas
preflight parodė `full_refresh_installed = false`; tai laukiamas senojo kelio
nebuvimo požymis, ne naujos migracijos klaida.

06:29:55 UTC skaitymo patikroje 06:25:00–06:29:11 UTC ciklas jau buvo
**sėkmingai baigęsis per 251 889 ms**: `requested_version = completed_version =
2105`, `last_status = refreshed`, `last_error = null`. 06:30:33 UTC būsena buvo
`clean`. Tai vienas po funkcijos pakeitimo tiesiogiai patikrintas ciklas.

Naudotojo atskira SQL Editor migracijos **„Success“ išvestis dar negauta**, todėl
formalus nuotolinio taikymo patvirtinimas nefiksuojamas; funkcijos apibrėžimas
ir ciklo rezultatas patikrinti atskirai. Naudotojo 06:25–06:29 UTC ciklo
[SQL Editor statinio cache patikra](../../supabase/tests/verify_catalog_static_size_reuse_read_only.sql)
grąžino `membership_reused_for_static_sizes = true`,
`old_static_rebuild_removed = true`, `phase_diagnostics_retained = true`,
`catalog_current = true`, `cache_matches_membership = true`, `last_error = null`
ir `last_duration_ms = 251889`. Tai atskirai patvirtina statinio cache turinio
lygybę paruoštai narystei ties 2105 versija. 06:42:33 UTC papildoma skaitymo
patikra rodė `requested_version = completed_version = 2105`, `last_status =
clean`, `last_error = null`; naujo refresh prašymo dar nebuvo. Produktų API
prieinamumas aktyvaus ciklo metu taip pat dar nepatikrintas.

## API matuoklio vietinė aplinka

Naudotojo pirmas 120 porų paleidimas sustojo ties `import psycopg` su
`ModuleNotFoundError`. Šis bandymas neišsiuntė API užklausų ir nesukūrė JSONL.
Projekto šaknyje sukurta ignoruojama `.venv` Python 3.14 aplinka ir įdiegtas
[prisegtas matuoklio paketas](../../scripts/benchmarks/requirements.txt)
`psycopg[binary]==3.3.4`. `pip check` nerado sugadintų priklausomybių;
`.venv` interpreteris sėkmingai prisijungė per tunelį kaip `codex_reader`,
įvykdė `BEGIN READ ONLY`, perskaitė 2105/2105 `clean` būseną ir baigė
`ROLLBACK`. Pirmas bandymas su žetono įvedimu buvo nutrauktas klaviatūra,
neišsiuntus API užklausų; vėlesnė sėkminga serija pateikta žemiau.

Pirmo segmento paleidimas PowerShell (žetoną skriptas paprašė įvesti paslėptai):

```powershell
.\.venv\Scripts\python.exe scripts/benchmarks/catalog_facets_api.py run --auto-manifest --api-base https://aboutyou-private-catalog-api.aurimas-zvirb.workers.dev --output docs/katalogo-filtravimas/API_BANDYMAS_2026-10-05_01.jsonl --per-group 20
```

## 06:57–07:01 UTC API matavimo pirmas segmentas

- [JSONL rezultatai](API_BANDYMAS_2026-10-05_01.jsonl) ir [manifestas](API_BANDYMAS_2026-10-05_01.manifest.json)
  priklauso katalogo **2105** versijai. Manifesto SHA-256
  `6d1addc732b28cc9e4fcd704504f4e41dd60f5103e6ea110f59bfef7f36a6e48`
  sutampa su JSONL metaduomenimis; abiejuose failuose nerasta
  `Authorization`, `Bearer`, `access_token` ar `refresh_token` žymų.
- Iš **45** bandytų porų visos **45 galioja** ir turi skirtingus normalizuotus
  cache raktus: `single`, `category_color`, `multi_group` po 8;
  `sizes`, `price_lpl`, `narrow` po 7. Visi **90 HTTP** atsakymų buvo 200,
  timeout **0**. Kiekvienu atveju prieš miss cache įrašo nebuvo, po jo įrašas
  atsirado, hit nepakeitė `created_at`, o abiejų atsakymų turinio SHA-256
  sutapo.
- Šio segmento HTTP miss p50 **3 583,87 ms**, p95 **5 032,35 ms**,
  maksimumas **6 214,52 ms**; hit p50 **195,92 ms**, p95 **418,57 ms**,
  maksimumas **478,73 ms**. Tai 45 porų segmento rezultatai, **ne**
  galutinis bent 120 porų p95 įvertis.
- Serija sustojo prieš kitą porą 07:01:57 UTC, kai `requested_version` pakilo
  iki 2106, o `completed_version` dar buvo 2105. Nė viena pora per versijos
  pasikeitimą nebuvo įskaityta. Iki plano minimumo trūksta bent **75**
  skirtingų porų: atitinkamai 12/12/12/13/13/13 per šešias grupes.
- 07:09:34 UTC skaitymo režimu patikrinta: 2106 versijos refresh baigėsi
  sėkmingai per **254 181 ms**, `last_error = null`; jau buvo paprašyta 2107
  versijos. Tai antras tiesiogiai stebėtas sėkmingas `CONCURRENTLY` ciklas.
- 07:13:31 UTC 2107 ciklo metu buvo suteiktas `ExclusiveLock` ant effective
  dydžių vaizdo. Toje pačioje `BEGIN READ ONLY` transakcijoje ribota
  `SELECT ... LIMIT 1` iš šio vaizdo baigėsi per **40,84 ms**, o iš
  `catalog_items_read` per **44,24 ms**. Tai patvirtina, kad šie DB skaitymai
  nebuvo blokuoti tuo stebėtu momentu; tai nėra autentifikuoto HTTP API
  bandymas. 07:14:42 UTC 2107 ciklas jau buvo sėkmingai baigtas per
  **252 060 ms**, `requested_version = completed_version = 2107`,
  `last_error = null`. Taip tiesiogiai stebėti trys sėkmingi `CONCURRENTLY`
  ciklai: 251,889, 254,181 ir 252,060 s.

Matuokliui pridėtas `--resume-from` parametras: jis patikrina ankstesnio
segmento manifestą, skaičiuoja tik galiojančius unikalius filtrų raktus ir
leidžia siekti po 20 kiekvienoje grupėje per kelias katalogo versijas.
Segmentų p95 skaičiuoti atskirai; bendrą p95 pateikti tik su visų segmentų
versijomis ir aiškiai nurodytu sujungimo būdu.

Antram segmentui naudotas paleidimas:

```powershell
.\.venv\Scripts\python.exe scripts/benchmarks/catalog_facets_api.py run --auto-manifest --api-base https://aboutyou-private-catalog-api.aurimas-zvirb.workers.dev --output docs/katalogo-filtravimas/API_BANDYMAS_2026-10-05_02.jsonl --per-group 20 --resume-from docs/katalogo-filtravimas/API_BANDYMAS_2026-10-05_01.jsonl
```

## 07:24 ir 07:28 UTC autentifikavimo klaidos

- [Antro segmento JSONL](API_BANDYMAS_2026-10-05_02.jsonl) ir [manifesto](API_BANDYMAS_2026-10-05_02.manifest.json)
  SHA-256 sutampa (`f0b450da5c33459569b8a98fd06912c673970f15b0eca2247e44a60b0b89b756`).
  Manifestas sudarytas iš stabilios 2108 versijos, bet abi išsiųstos miss
  užklausos grąžino **HTTP 401** ir `Neteisinga arba pasibaigusi sesija`.
  Hit užklausų bei naujų cache įrašų nebuvo; **0 galiojančių porų**.
- [Trečio segmento JSONL](API_BANDYMAS_2026-10-05_03.jsonl) ir [manifesto](API_BANDYMAS_2026-10-05_03.manifest.json)
  SHA-256 taip pat sutampa (`75b14cdb3023bb3c4dc6c5cb7256767c57a3b3add6483a146003c3caa277fc26`).
  Dar dvi miss užklausos grąžino tą patį **401**, be hit ir be cache įrašo;
  **0 galiojančių porų**. Abiejų segmentų failuose nerasta žetono žymų.
- Trečias paleidimas nurodė tik antrą JSONL per `--resume-from`, o antrame
  galiojančių porų nėra. Todėl jo metaduomenų `prior_valid_pairs = 0` **nėra**
  visos matavimo istorijos suma: pirmo segmento **45** poros tebegalioja.
  Matuoklis pataisytas, kad nuo šiol automatiškai sektų ankstesnių segmentų
  `resume_from` grandinę. Patikra su `--resume-from 03` teisingai randa visas
  45 unikalias 2105 versijos poras, neįtraukdama keturių 401 atsakymų.

Galiojantis progresas tebėra **45/120**; 45 porų p95 lieka **5 032,35 ms**.
401 atsakymų laikai į našumo statistiką neįtraukiami. Prieš kitą bandymą
reikia naujo galiojančio prisijungusios sesijos access token; kopijuoti tik
žetono reikšmę be `Bearer` prefikso ir jos nesaugoti faile ar pokalbyje.
Matuoklis dabar sustoja po pirmo 401 arba 403 su aiškia priežastimi.

Ketvirtam segmentui naudotas paleidimas su nauju žetonu:

```powershell
.\.venv\Scripts\python.exe scripts/benchmarks/catalog_facets_api.py run --auto-manifest --api-base https://aboutyou-private-catalog-api.aurimas-zvirb.workers.dev --output docs/katalogo-filtravimas/API_BANDYMAS_2026-10-05_04.jsonl --per-group 20 --resume-from docs/katalogo-filtravimas/API_BANDYMAS_2026-10-05_03.jsonl
```

## 07:44–07:51 UTC galutinis 120 porų matavimas

- [Ketvirto segmento JSONL](API_BANDYMAS_2026-10-05_04.jsonl) ir
  [manifesto](API_BANDYMAS_2026-10-05_04.manifest.json) SHA-256 sutampa:
  `9981e2c70c5240f388d67c6754e1d4995a044246030767af88f556b585dbb452`.
  Manifestas sukurtas iš stabilios **2109** katalogo versijos. Segmentas
  baigėsi be nutraukimo: **75/75** galiojančių naujų porų, **150/150** HTTP
  200, **0** timeout. Jo miss p50 **3 536,85 ms**, p95 **4 228,02 ms**;
  hit p50 **176,82 ms**, p95 **346,36 ms**.
- Nepriklausomai perskaityti visi keturi JSONL ir jų manifestai. Visų
  manifestų SHA-256 sutampa su atitinkamais JSONL; kiekvienam galiojančiam
  atvejui sutampa miss/hit atsakymų turinio SHA-256, prieš miss cache rakto
  nebuvo, po hit jo `created_at` nepasikeitė, o katalogo versija per porą
  nesikeitė. **120** galiojančių porų turi **120 skirtingų normalizuotų
  filtrų raktų**: 45 iš 2105 ir 75 iš 2109 versijos. Kiekvienoje iš šešių
  grupių yra po **20** porų. 02 ir 03 segmentų keturi HTTP 401 atskirti nuo
  našumo imties; iš viso galiojančiose porose buvo **240/240 HTTP 200** ir
  **0 timeout**. Ketvirto segmento failuose nerasta žetono žymų.
- Sujungiant 2105 ir 2109 segmentų galiojančias poras ir naudojant tą patį
  linijinį procentilio interpoliavimą kaip matuoklyje, HTTP miss p50 yra
  **3 537,36 ms**, p95 **4 643,44 ms**, maksimumas **6 214,52 ms**;
  hit p50 **180,96 ms**, p95 **353,53 ms**, maksimumas **478,73 ms**.
  Atskirų versijų miss p95: **5 032,35 ms** (2105, n=45) ir
  **4 228,02 ms** (2109, n=75). Bendras p95 yra **3 356,56 ms** žemiau
  8 s ribos; didžiausias stebėtas miss – **1 785,48 ms** žemiau jos.

| Scenarijų grupė | Galiojančios poros | Miss mediana, ms | Didžiausias miss, ms |
| --- | ---: | ---: | ---: |
| Vienas platus filtras (`single`) | 20 | 3 881,89 | 6 214,52 |
| Kategorija ir spalva (`category_color`) | 20 | 3 444,78 | 4 174,97 |
| Kelios grupės (`multi_group`) | 20 | 3 265,51 | 4 129,18 |
| Dydžiai (`sizes`) | 20 | 3 810,20 | 4 794,17 |
| Kaina / LPL (`price_lpl`) | 20 | 3 222,90 | 5 465,11 |
| Siauri deriniai (`narrow`) | 20 | 3 504,49 | 4 635,51 |

Šis matavimas **atitinka 120 skirtingų porų ir <8 s miss p95 kriterijų**
atrinktiems scenarijams, su daugiau nei 3 s p95 atsarga. Jis neparodo
produkto API elgsenos vykstant refresh ir dar neatstoja pakartojimo kitu
metu bei filtrų semantikos / UI priėmimo testų. Pagal šiuos rezultatus naujo
DB optimizavimo šiuo metu nereikia planuoti; kitas prioritetas yra
funkcinis tikslumas ir sąsajos patikimumas.

## Tolesnė eiga

1. Kito natūraliai paprašyto refresh metu patikrinti autentifikuotų produktų
   ir facetų API prieinamumą. Po ciklo skaitymo režimu įrašyti trukmę,
   versijas ir klaidą.
2. Patikrinti filtrų ir alertų rezultatų semantiką realiais scenarijais:
   kelių dydžių `OR`, skirtingų grupių `AND`, `42,5`, senus tokenus,
   `otherSizes`, override ir cache invalidavimą.
3. Užbaigti desktop/mobile filtro meniu stabilumą, pasenusių API atsakymų
   apsaugą ir klaviatūros scenarijus. Pakartoti API matavimą kitu metu;
   jei p95 priartės prie 8 s arba atsiras timeout, optimizuoti pagal naujus
   konkrečius planus.
4. Naudotojo atskirą SQL Editor migracijos „Success“ išvestį užfiksuoti, kai
   ji bus pateikta. Migracijos nekartoti vien dėl po jos gauto
   `full_refresh_installed = false`.
