# Katalogo filtravimo patobulinimų planas

**Bendras progresas:** 34/100 (kontekstinio cache pataisa pritaikyta ir patikrinta VPS; likę normalizavimo bei UX blokatoriai)
**Būsena:** `5cf9817` nepriimtas, tačiau kategorijos ir viso filtro kontekstą naudojanti dydžių cache pataisa jau veikia VPS; kelių filtrų UX, alertų predikatų suvienodinimas ir likę normalizavimo darbai dar neįgyvendinti
**Prioritetas:** aukštas, nes dabartinis elgesys lėtina kasdienę produktų paiešką

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
- [ ] Įgyvendinti draft/applied filtrus, stabilų atidaryto meniu snapshot,
  `router.replace`/istorijos strategiją, debounce ir užklausų atšaukimą arba seką.
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

- [ ] `CatalogFilters.vue` atskirti draft ir patvirtintą filtro būseną.
- [ ] Nustoti kviesti pilną `apply()` po kiekvieno grupės checkbox paspaudimo.
- [ ] Pridėti `Taikyti / Rodyti N prekių` veiksmą desktop filtro meniu.
- [ ] Mobile apatinį mygtuką susieti su draft filtrų patvirtinimu.
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
- [ ] Įdiegti draft/patvirtintų filtrų būseną ir realų `Taikyti` veiksmą.
- [ ] Apsaugoti sąsają nuo pasenusių užklausų atsakymų.
- [ ] Padengti kelių checkbox pasirinkimą testais.

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
