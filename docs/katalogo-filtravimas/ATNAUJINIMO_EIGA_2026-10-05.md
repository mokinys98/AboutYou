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

## 08:14–08:22 UTC papildoma ciklo ir prieigos patikra

- Patikrinta per esamą `127.0.0.1:15432` tunelį su `codex_reader`; TCP
  patikra ir tikras PostgreSQL prisijungimas pavyko. Kiekvienas būsenos
  nuskaitymas buvo atskiroje `BEGIN READ ONLY` transakcijoje, kuri užbaigta
  `ROLLBACK`.
- 08:14:23 UTC pradinė būsena buvo `requested_version = completed_version =
  2111`, `last_status = clean`, `last_error = null`. Paskutinis užbaigtas
  refresh prasidėjo 08:05:00.029 UTC ir baigėsi 08:08:59.833 UTC; trukmė
  **239 803 ms**.
- 08:17:42 UTC pirmą kartą pastebėtas `requested_version = 2112`, o
  `completed_version` liko 2111 ir `last_status = pending`. Stebėjimas tęstas
  iki 08:22:16 UTC: 2112 vis dar buvo `pending`, `refresh_started_at` ir
  `refresh_completed_at` nepasikeitė, `last_error` liko null. Abiem užklausos
  langais nebuvo nei `ExclusiveLock`, nei `AccessExclusiveLock` ant
  `catalog_effective_size_membership_read`. Tai naujas refresh prašymas, bet
  ne užbaigtas 2112 ciklas; šio bandymo metu API prieinamumo ciklo metu
  patvirtinti negalima.
- Papildomai bandyta tik skaityti peržiūrėti `cron.job_run_details`, kad būtų
  galima susieti prašymą su suplanuoto darbo paleidimu. PostgreSQL grąžino
  `permission denied for schema cron`; transakcija atšaukta. Tai prieigos prie
  cron istorijos apribojimas, ne refresh ar migracijos klaida.
- Browser įrankio inicijavimas grąžino `No browser is available`, o prieinamų
  naršyklių sąrašas buvo tuščias. Todėl nebuvo prieigos prie prisijungusio
  naudotojo sesijos ir **nebuvo siųstos autentifikuotų** `/v1/catalog` ar
  `/v1/catalog/facets` užklausos. Žetonas nebuvo skaitomas, prašytas ar įrašytas.
  Galiojanti 120 porų imtis lieka ankstesniame skyriuje ir šiame bandyme
  nebuvo keista.
- Dėl tos pačios priežasties realūs filtro tikslumo ir UI scenarijai nebuvo
  paleisti: kelių dydžių OR, skirtingų filtrų grupių AND, `42,5`, seni dydžių
  tokenai, `otherSizes`, override/cache invalidavimas, greitas checkbox
  pasirinkimas bei patvirtinimas desktop ir mobile meniu. Jokių klaidingų
  rezultatų ar UI klaidų nebuvo stebėta, nes scenarijai nepasiekė aplikacijos;
  tai nelaikoma sėkmingu priėmimo testu.

### Atkūrimas ir tęsinys

1. Prijungti arba atidaryti prisijungusią Browser sesiją ir tęsti šiame
   dokumente; sesijos žetono į pokalbį siųsti nereikia.
2. Kito natūraliai prasidėjusio katalogo refresh metu užfiksuoti būseną prieš
   ciklą, po jo ir API atsakymus. Nekviesti refresh funkcijos bandymo tikslais.
   Ciklas laikomas baigtu tik kai `requested_version = completed_version`,
   `last_status` yra `refreshed` arba `clean`, o `last_error` null.
3. Prisijungusioje aplikacijoje patikrinti `/v1/catalog` ir
   `/v1/catalog/facets` HTTP atsakymus prieš ciklą, jo metu ir po jo; įrašyti
   statusą, laiką, katalogo versiją ir klaidos tekstą, bet ne žetono antraštę.
4. Desktop ir mobile pakartoti `docs/katalogo-filtravimas` skyriuje
   „Testavimo scenarijai“ išvardytus realius atvejus. Kiekvienam įrašyti
   pasirinktas reikšmes, matomą rezultatą, URL/chip būseną, ekrano dydį ir
   tikslius atkūrimo veiksmus; patikrinti, kad uždarant mobile meniu be
   patvirtinimo juodraštis atmetamas, o patvirtinus pritaikomas.

## 09:10–09:19 UTC: natūralus ciklas ir prisijungusio katalogo patikra

- Per esamą VPS tunelį tik skaitymo transakcijoje: 09:14:35 UTC būsena buvo
  `requested_version = completed_version = 2115`, `last_status = refreshed`,
  `last_error = null`; ciklas prasidėjo 09:10:00.097 ir baigėsi 09:14:04.894 UTC,
  trukmė **244 797 ms**. 09:19:08 UTC būsena jau buvo `clean`; tikrintų
  `catalog_effective_size_membership_read` ilgų išskirtinių užraktų nerasta.
  Refresh nebuvo paleistas bandymo tikslais.
- Po šio ciklo prisijungusioje Chrome sesijoje atvertas pradinis katalogas:
  rodomi **99 238** produktai, produkto kortelės ir filtro grupės. Produktų bei
  facetų duomenys aplikacijoje pasiekiami po ciklo, tačiau ši naršyklės jungtis
  neparodė DevTools Network HTTP statusų ar atsakymų trukmių. Todėl tai yra
  sėkmingo UI duomenų pateikimo patvirtinimas, o ne tiesioginis teiginys, kad
  užfiksuoti konkretūs `/v1/catalog` ir `/v1/catalog/facets` HTTP 200 atsakymai.
  Ciklo metu atskirų HTTP atsakymų neužfiksavau.
- Desktop scenarijai:
  - `Vyrams > Batai` kategorija + dydis `42,5` parodė 828 batus. Pridėjus
    spalvą `Black`, rezultatas sumažėjo iki 203. Produktų pavyzdžiai buvo batai;
    skirtingos filtrų grupės veikia kaip AND.
  - Toje pačioje kategorijoje pasirinkus dydžius `42,5` ir
    `42,5 NORMALUS / NORMALUS`, o palikus `Black`, matyta 205 produktų;
    matomos prekės buvo juodi batai. Tai suderinama su dydžių OR elgsena.
  - Kataloge be kategorijos pasirinkus grupėje „Suderinamumas: telefono dėklai“
    dydžius `42,5` ir `42,5-43`, gauta 10 produktų, tarp jų adidas bėgimo
    bateliai „Galaxy 8“ ir „Galaxy 7“. Tai klaidingi rezultatai: telefono dėklo
    dydžio filtras įtraukė batus. Atkūrimas: pradinis katalogas → „Dydis“ →
    paieškoje `42,5` → pasirinkti abu dydžius telefono dėklų grupėje →
    „Taikyti filtrus“.
  - Dydžių meniu leido palikti kelis pasirinkimus juodraštyje, parodydavo
    „Pakeitimai dar nepritaikyti“ ir „Taikyti filtrus“. Pridėjus trečią dydį ir
    paspaudus „Atšaukti“, URL bei 2 pritaikyti dydžiai liko nepakitę.
- UI būsena: pritaikius filtrus kelis kartus buvo matomas tekstas
  „Atnaujinami filtrai…“ ir kartais „Atnaujinamos prekės…“, nors produktų
  sąrašas ir rezultato skaičius jau buvo pateikti. Įprastos klaidos juostos ar
  tuščio sąrašo nepastebėjau; būsenos tekstas gali užstrigti arba vėluoti.
- Mobile meniu šiame bandyme nepatikrintas: turimas Chrome valdymas neleido
  nustatyti mobiliojo peržiūrosporto. Mobiliojo meniu uždarymo ir juodraščio
  atmetimo rezultatų neišgalvoju.
- Baigus naršyklės bandymus pašalinti laikini filtrai ir atkurta pradinė
  prisijungusio katalogo būsena (`/`); produktai ir filtrų grupės užsikrovė.
  API našumo 120 porų imtis nepakeista ir nekartota.

### Tęstiniai veiksmai

1. Klaidingą telefono dėklo dydžio facetą atkurti aukščiau nurodytais veiksmais;
   patikrinti API/indekso klasifikavimo šaltinį ir pašalinti ne batų reikšmių
   patekimą į batų rezultatus. Šis bandymas tik atskleidė klaidą; duomenų bazė
   nekeista.
2. Jei reikia įrodyti HTTP kodus ir trukmes vykstant kitam natūraliam refresh,
   naudoti prisijungusio Chrome Network įrašus arba iš anksto autorizuotą
   matavimo įrankį; palyginti `/v1/catalog` ir `/v1/catalog/facets` prieš,
   per ir po ciklo. Nekartoti 120 porų imties be poreikio.
3. Atskirame mobile viewport bandyme pakartoti kelių dydžių pasirinkimą,
   pritaikymą ir uždarymą be patvirtinimo; užfiksuoti ekrano plotį ir juodraščio
   būseną.
4. Patikrinti, kodėl „Atnaujinami filtrai…“ lieka matomas jau pateikus
   rezultatus.

## API refresh probe paruošimas

- Sukurtas `scripts/benchmarks/catalog_refresh_probe.py`. Jis matuoja po vieną
  `/v1/catalog` ir `/v1/catalog/facets` užklausą stabilioje būsenoje, per
  natūralų refresh ir po jo; renka statusą, trukmę, atsakymo baitų skaičių,
  versijas, stebimų read modelių užraktus ir pradinio `{}` facetų cache būseną.
  Atsakymų turinys ir `Authorization` antraštė nerašomi. Užklausos nekeičia
  cache valdymo antraštėmis. DB stebėjimas vykdomas tik `BEGIN READ ONLY` /
  `ROLLBACK` sesijomis per patvirtintą tunelį.
- Patikrinta: skriptas kompiliuojasi, `--help` veikia, o tiesioginė DB snapshot
  patikra per tunelį grąžino `requested_version = completed_version = 2115`,
  būseną `clean`, stebimuose modeliuose refresh užraktų nebuvo, `{}` facetų
  cache įrašas buvo. Produkcinėje DB nieko nekeista.
- Po šio įrašo probe paleistas matomame PowerShell lange su šviežiu tokenu;
  tokenas į failą ar šį žurnalą nepateko. Žali įrašai:
  `API_REFRESH_PROBE_2026-10-05.jsonl`. Jokio refresh bandymo tikslais
  neinicijavau; 120 porų imtis nekartota.

## 09:50–09:59 UTC: API matavimas per natūralų refresh

- Abi pradinės užklausos stabilioje versijoje `2115/2115` grąžino HTTP 200:
  `/v1/catalog` **225 ms** (80 586 baitų), `/v1/catalog/facets` **784 ms**
  (2 056 862 baitai). Tuo metu refresh užraktų nebuvo, `{}` facetų cache
  įrašas buvo.
- Natūralus refresh pakėlė prašomą versiją `2115 → 2116`. Aktyvus langas
  užfiksuotas, kai `catalog_items_read` turėjo suteiktą `ExclusiveLock`, o
  versijos buvo `2116/2115`, būsena `pending`. Abu API atsakymai išmatuoti šio
  lango viduje ir prieš bei po jų DB snapshot patvirtino tą pačią versijų
  neatitiktį bei užraktą: `/v1/catalog` HTTP 200, **3 448 ms**, 80 586 baitų;
  `/v1/catalog/facets` HTTP 200, **652 ms**, 2 056 862 baitai. Kitų dviejų
  stebėtų read modelių užraktai snapshotuose tuo metu nepasirodė.
- Ciklas baigėsi sėkmingai: `2116/2116`, `last_status = refreshed`, be klaidos,
  trukmė **264 465 ms** (~4 min. 24 s); po jo stebimų refresh užraktų neliko.
  Po ciklo `/v1/catalog` grąžino HTTP 200 per **286 ms** (80 586 baitų), o
  `/v1/catalog/facets` HTTP 200 per **4 771 ms** (2 057 226 baitų). Visi šeši
  API atsakymai buvo HTTP 200 ir trumpesni už dokumentuotą **8 s** ribą; 401,
  403, 5xx, timeout ar kitų transporto klaidų neužfiksuota.
- Facetų `{}` cache įrašas buvo prieš refresh ir per aktyvaus lango užklausą;
  iškart po refresh, prieš facetų API kvietimą, jo nebuvo, o po kvietimo atsirado.
  Tai suderinama su įprastu facetų endpointo cache užpildymu; cache rankiniu būdu
  nekeistas. `/v1/catalog` Cloudflare cache būsena prieš ir po refresh buvo
  `HIT`; aktyviame etape ši antraštė negrąžinta, todėl to etapo edge cache
  rezultato nepažymiu.
- Rezultatas `captured_refresh_cycle_all_requests_200_under_threshold` reiškia,
  kad abu autentifikuoti endpointai buvo užklausti visose trijose fazėse, aktyvūs
  kvietimai susieti su versijos atsilikimu ir realiu read-modelio užraktu, visi
  atsakymai sėkmingi ir greitesni nei 8 s. Lėčiausias buvo facetų kvietimas po
  refresh (**4,77 s**); šio vieno matavimo nepakanka teigti apie bendrą p95 ar
  kitų ciklų greitį. Atkūrimas: vėl paleisti probe matomame PowerShell su šviežiu
  tokenu ir laukti kito natūralaus ciklo; neinicijuoti refresh rankiniu būdu.

## 2026-10-06 `{}` facetų cache prewarm stebėjimas

- VPS per `codex_reader` ir `BEGIN READ ONLY` patikrinta, kad
  `invalidate_catalog_facets_cache()` kviečia
  `catalog_facets_cached('{}'::jsonb)`. Versijos **2191** refresh baigėsi
  `clean`; `{}` cache įrašas buvo, jo payload objektas turėjo kategorijų.
  Trukmė `last_duration_ms = 261417` (4 min. 21 s).
- 2026-10-05 atskaitoje pirmas `/v1/catalog/facets` atsakymas po refresh truko
  **4770,71 ms**, kai `{}` cache dar nebuvo. Naujo ciklo **2197** probe užfiksavo
  po-refresh facetų atsakymą per **637,88 ms** — **4132,83 ms (86,6 %) trumpiau**.
  Tai vienas pirmo atsakymo matavimas, ne p95 įvertis.
- [Pilnas autentifikuotas probe](API_REFRESH_PROBE_2026-10-06v1.jsonl) apėmė
  ciklą **2197**. Prieš jį versija 2196 buvo stabili, po jo 2197 baigėsi
  `refreshed`, trukmė **259730 ms** (4 min. 20 s), `last_error = null`, `{}`
  cache įrašas buvo. Visų šešių API atsakymų būsenos buvo 200 ir laikai nesiekė
  8 s ribos:

  | Fazė | Katalogas | Facetai | Refresh užraktas | `{}` cache |
  | --- | ---: | ---: | --- | --- |
  | Prieš ciklą | 1739,67 ms | 925,76 ms | nėra | yra |
  | Ciklo metu | 2721,82 ms | 686,37 ms | yra | yra |
  | Po ciklo | 342,10 ms | 637,88 ms | nėra | yra |

- Po-refresh API snapshotuose jau buvo prašyta versijos **2198** (`2198/2197`),
  bet tuo metu stebimų read-modelių refresh užraktų dar nebuvo. 06:54 UTC
  atskira read-only patikra matė 2198 ciklo aktyvius užraktus. Jis baigėsi
  06:54:15 UTC: `2198/2198`, `clean`, `last_error = null`, trukmė **255742 ms**
  (4 min. 16 s), `{}` cache įrašas yra, stebimų užraktų neliko. Tai antras
  iš eilės patvirtintas ciklas su cache įrašu; šio ciklo API užklausų probe
  nefiksavo. [Read-only įrašas](API_REFRESH_STATE_PROBE_2026-10-06_2198.jsonl).
- Pirmas bandymas faile
  [API_REFRESH_PROBE_2026-10-06.jsonl](API_REFRESH_PROBE_2026-10-06.jsonl)
  nepilnas (`probe_error`, be request įrašų); jo rezultatų į našumo skaičius
  neįtraukiau. Galutiniam vertinimui naudotas tik `v1` failas.
- [Read-only būsenos probe](API_REFRESH_STATE_PROBE_2026-10-06.jsonl)
  05:24:33–05:31:35 UTC ciklo nepagavo (`no_active_refresh_observed`), versija
  liko `2191/2191`, o `{}` cache įrašas išliko. Jis refresh neinicijavo ir API
  užklausų nesiuntė.

### Papildomi bandymai v2–v4

- [v2 įrašas](API_REFRESH_PROBE_2026-10-06v2.jsonl), 07:01:59–07:08:00 UTC:
  pradinis stabilus langas per 360 s neatsirado (terminalo išvestyje matyti
  besikeičiantys laukiami refresh prašymai). JSONL turi tik `run` ir bendrą
  `RuntimeError` įrašą, jame nėra API užklausų. Tai nėra API trukmės matavimas.
- [v3 įrašas](API_REFRESH_PROBE_2026-10-06v3.jsonl), 07:39:49–07:44:40 UTC:
  pradinis DB snapshotas buvo stabili `2201/2201` būsena, tačiau abu pradiniai
  API kvietimai grąžino HTTP 401 (`unauthorized`): katalogas **234,56 ms**,
  facetai **52,65 ms**. Probe sustojo prieš natūralaus refresh laukimą;
  šių laikų neįtraukiu į API veikimo palyginimą. Pakartotinis paleidimas tuo
  pačiu v3 išvesties keliu sustojo dar prieš probe pradžią, nes failas jau buvo;
  įrašas nekeistas. Jei bandymas kartojamas, reikia naujo failo vardo ir
  paslėptai įvedamo galiojančio tokeno.
- [v4 įrašas](API_REFRESH_PROBE_2026-10-06v4.jsonl), 07:48:11–07:59:23 UTC:
  visas refresh langas užfiksuotas: `2201/2201` stabili būsena, tada
  `2202/2201` su `ExclusiveLock`, o po ciklo `2202/2202`, `refreshed`, be
  `last_error`; trukmė **258 413 ms** (4 min. 18 s). `{}` facetų cache įrašas
  buvo prieš ciklą, per jį ir po jo. Visi šeši API kvietimai grąžino HTTP 400
  su tuščiu atsakymo turiniu: katalogas **50,41 / 104,37 / 52,37 ms**, facetai
  **48,65 / 61,70 / 68,84 ms** (prieš / per / po ciklą). Šie laikai aprašo tik
  greitai atmestas užklausas; jie nėra sėkmingų API atsakymų ar prewarm
  pagerėjimo matas. Žurnale įrašytas tik saugus `http_client_error` aprašas,
  ne atsakymo turinys, todėl iš šio įrašo negalima nustatyti konkrečios 400
  priežasties.
- Nei v2, nei v3, nei v4 nekeičia ankstesnio galiojančio v1 palyginimo:
  v1 tebėra vienintelis sėkmingas po-prewarm API matavimas (**637,88 ms**
  facetams po refresh, HTTP 200). Pakartojimo reikia, kai bus aiški v4 HTTP 400
  priežastis ir bus galima gauti 200 atsakymus; refresh bandymo metu rankiniu
  būdu neinicijuoti. Visuose v2–v4 JSONL nerasta tokeno ar `Authorization`
  antraštės žymių.

## 2026-10-06 tęsinys: dydžių klaida ir vietinis patikimumo taisymas

- Prisijungusioje produkcinėje naršyklėje šakniniame kataloge dydžių paieška
  `42,5` vis dar rodo grupę „Suderinamumas: telefono dėklai“ su `42,5` ir
  `42,5-43`. Tai patvirtina, kad ankstesnis UI radinys nėra vien istorinis.
- Per autorizuotą `127.0.0.1:15432` tunelį tik `BEGIN READ ONLY` transakcijose
  nustatyta priežastis: gyva `catalog_size_domain` funkcija pirmiau tikrina
  `iphone|ipad|galaxy|pixel|telefon|telefono dėkl` ir tik paskui batų
  kategoriją. Bazinėje `catalog_size_facets_read` materializuotoje peržiūroje
  yra 62 `device_cases` produktai; 53 jų pavadinime turi `Galaxy`, 20 aiškiai
  yra batai. Būtent du `device_cases:42.5` ir `device_cases:42.5-43` effective
  tokenai priklauso 11 `ADIDAS PERFORMANCE` „Galaxy 7/8“ bėgimo batų. Šiems
  produktams override įrašų nėra. Root facetų cache ir effective narystė šiuo
  metu sutampa; klaida atsiranda jau bazinėje klasifikacijoje.
- Paruošta [migracija](../../supabase/migrations/20261006110000_remove_device_case_size_inference.sql)
  pašalina pavadinimo pagrindu daromą telefono dėklų spėjimą. Ji **dar
  nepritaikyta VPS** ir pati nepaleidžia refresh. Kitas natūralus katalogo
  atnaujinimas turi perskaičiuoti bazinį dydžių vaizdą, effective narystę ir
  root facetų cache. [Skaitymo režimo patikros
  SQL](../../supabase/tests/verify_device_case_size_inference_read_only.sql)
  prieš migraciją sintaksiškai įvykdytas: pirmi keturi požymiai, kaip laukta,
  buvo `false`, o cache bei `2215/2215 clean` refresh būsena — `true`.
- Vietiniame katalogo puslapyje papildomai apribota produktų bei facetų
  užklausų trukmė iki 15 s, pasenusios produktų užklausos atšaukiamos, o
  pakartotinė to paties rakto facetų užklausa prisijungia prie jau vykstančio
  atnaujinimo prieš imdama seną browser cache. Pašalintas išankstinis
  kategorijos `loading=true`, galėjęs užstrigti nepakeitus maršruto. Tai
  **vietinis, dar nedeployintas** pakeitimas. `npm test`: 165/165; visų
  workspace tipų patikra baigėsi kodu 0 (Wrangler tik pranešė, kad ribota
  aplinka neleido įrašyti debug log failo už workspace ribų).
- Prisijungusioje produkcinėje naršyklėje su **390 × 844 px** viewport patikrintas
  mobile juodraštis: pasirinkus `Kiti aksesuarai > S`, `Pasirinkta` tapo 1,
  tačiau URL liko `/`; uždarius meniu be patvirtinimo ir vėl atidarius,
  `Pasirinkta` grįžo į 0. Pakartojus pasirinkimą ir paspaudus apatinį
  „Taikyti filtrus“, URL tapo `/?sizes=accessories%253As`, produktų skaičius
  tapo 2, meniu užsidarė. Po bandymo URL grąžintas į `/`, o laikinas viewport
  pakeitimas atšauktas. Tai produkcinio UI juodraščio patikra, ne dar
  nedeployintos užklausų pataisos patikra.
- [Pirmas pakartotinis API probe v5](API_REFRESH_PROBE_2026-10-06v5.jsonl)
  sustojo ties terminalo tinklo leidimų `PermissionError` prieš gaudamas HTTP
  atsakymą; jokio API našumo mato iš jo nedarau. [V6
  probe](API_REFRESH_PROBE_2026-10-06v6.jsonl) paleistas su tinklo leidimu ir
  šviežiu tokenu. Ciklas **2216/2216** baigėsi `refreshed`, be klaidos, per
  **284 342 ms** (~4 min. 44 s); `{}` facetų cache buvo visose trijose fazėse.
  Visi šeši autentifikuoti API atsakymai buvo HTTP 200, trumpesni už 8 s; per
  aktyvias užklausas DB prieš ir po jų rodė `2216/2215` ir refresh užraktą:

  | Fazė | Katalogas | Facetai |
  | --- | ---: | ---: |
  | Prieš ciklą | 193,59 ms | 894,37 ms |
  | Ciklo metu | 229,68 ms | 1 062,64 ms |
  | Po ciklo | 312,92 ms | 609,80 ms |

  Tai antras sėkmingas po-prewarm ciklo API matavimas; pirmas facetų atsakymas
  po refresh panašus į 2197 ciklo **637,88 ms**, bet dviejų ciklų neužtenka
  p95 išvadai. V6 JSONL turi 6 užklausas, `Authorization`, `Bearer`,
  `access_token`, `refresh_token` ir JWT pradžios žymų jame nerasta. V4 HTTP
  400 tiksli priežastis lieka nežinoma; su nauju tokenu šiame cikle ji
  nepasikartojo.
