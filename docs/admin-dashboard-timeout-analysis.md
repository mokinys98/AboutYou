# Admin dashboard 500 klaidos analizė

## Santrauka

`https://aboutyou-private-catalog-web.pages.dev/admin` neužkrauna administravimo
duomenų todėl, kad viena ar daugiau Supabase Data API užklausų viršija Postgres
`statement_timeout`. Worker veikia ir autentifikacija praeina, tačiau laukdamas
Supabase atsakymo gauna DB klaidą ir grąžina HTTP 500.

Pagrindinis gedimo mechanizmas:

1. Admin puslapis vienu metu paleidžia penkis API endpointus.
2. `/v1/admin/dashboard` vienu metu paleidžia dar šešiolika DB užklausų.
3. Dalis jų vykdo tikslius skaičiavimus per brangų gyvą `catalog_items` view arba
   kviečia nekeshuotą kategorijų agregavimo RPC.
4. `/v1/admin/brand-tiers` kiekvieną kartą perskaičiuoja brandų agregatą iš visos
   `products` lentelės.
5. Supabase PostgREST užklausoms galioja 8 s riba. DB I/O apkrovos metu užklausos
   peržengia ribą ir nutraukiamos.
6. Kadangi tiek API, tiek UI naudoja `Promise.all`, vienos užklausos klaida numuša
   visą dashboard atsakymą ir viso admin puslapio pradinį užkrovimą.

Tai nėra CORS, neteisingo JWT ar Cloudflare Worker CPU limito problema.

## Incidento požymiai

Pateiktame Cloudflare Worker įvykyje:

- HTTP atsakymas yra 500;
- Worker `outcome` yra `ok`;
- CPU sunaudota tik 2 ms;
- bendra užklausos trukmė yra apie 8,9 s;
- `Authorization` antraštė yra pateikta;
- užklausa ateina iš leistino Pages domeno.

Mažas CPU laikas ir beveik devynių sekundžių wall time reiškia, kad Worker
neatlieka sunkaus skaičiavimo. Jis laukia išorinės Supabase užklausos, kuri po
timeout grįžta su klaida.

## Produkcijos diagnostikos rezultatai

Analizės metu atliktos tik read-only užklausos į produkcijos Supabase projektą.

### Timeout konfigūracija

Produkcijos rolėms nustatyta:

| Rolė | `statement_timeout` |
| --- | ---: |
| `anon` | 3 s |
| `authenticated` | 8 s |
| `authenticator` | 8 s |
| `service_role` | atskiro nustatymo nėra |

Worker naudoja `service_role` raktą per Supabase REST/PostgREST. Kadangi
`service_role` neturi atskiro limito, šiam keliui praktiškai galioja
`authenticator` 8 s riba.

### Užfiksuotos DB klaidos

Postgres loguose tuo pačiu laikotarpiu pakartotinai registruota:

```text
canceling statement due to statement timeout
```

Supabase API loguose užfiksuoti konkretūs 500 atsakymai:

```text
POST /rest/v1/rpc/catalog_category_facets                         -> 500
HEAD /rest/v1/catalog_items?select=id                             -> 500
HEAD /rest/v1/catalog_items?select=id&is_premium=eq.true          -> 500
GET  /rest/v1/catalog_items_read?...                              -> 500
```

Tuo pat metu `team_members`, `sync_targets`, `sync_runs` ir autentifikacijos
užklausos grįžo su 200/206. Tai patvirtina, kad vartotojo sesija, admin narystės
patikrinimas ir CORS veikia.

### Užklausų trukmės

`pg_stat_statements` statistikoje matyta:

| Užklausa | Vidurkis | Maksimumas | Vertinimas |
| --- | ---: | ---: | --- |
| `brand_tier_admin_items` | ~1,97 s | ~7,41 s | labai arti 8 s ribos |
| `catalog_category_facets` | ~2,63 s | ~7,93 s | praktiškai ties timeout riba |
| tikslus `catalog_items` count | ~2,37–3,03 s | iki ~21,38 s | nestabilus, timeout tikėtinas |
| `product_detail_sync_summary` | ~0,48 s | ~7,50 s | apkrovos metu rizikingas |

Pateikto `/brand-tiers` Worker įvykio ~8,9 s trukmė atitinka užklausą, nutrauktą
Postgres 8 s timeout ir papildomą tinklo bei Worker atsakymo laiką.

### Duomenų ir read modelio apimtis

Analizės metu produkcijoje buvo:

| Objektas | Apimtis |
| --- | ---: |
| `products` | ~50 445 eilutės, ~107 MB |
| `catalog_items_read` | ~47 368 eilutės, ~225 MB |
| `catalog_item_facet_values_read` | ~1 020 546 eilutės, ~143 MB |
| `brand_tiers` | ~106 eilučių, ~80 KB |

Problema nėra maža `brand_tiers` lentelė. Brangi yra
`brand_tier_admin_items` view užklausa, nes ji kiekvieną kartą skaito ir grupuoja
`products`.

## Kodo priežastys

### 1. Admin puslapio `Promise.all`

`apps/web/pages/admin.vue` pradiniame `refresh()` vienu metu kviečia:

```text
/v1/admin/dashboard
/v1/sync-targets
/v1/sync-runs
/v1/admin/users
/v1/admin/brand-tiers
```

`Promise.all` atmeta visą rezultatą, jei nepavyksta bent vienas endpointas. Todėl
net veikiant vartotojų, sync ir daliai dashboard užklausų, puslapis rodo bendrą
užkrovimo klaidą.

Papildomai kiekvienas endpointas atskirai atlieka JWT ir `team_members`
patikrinimą. Vienas admin puslapio atidarymas dėl to sukuria kelias vienodas
narystės užklausas.

### 2. Dashboard vienu metu paleidžia šešiolika DB užklausų

`apps/api/src/index.ts` `/v1/admin/dashboard` maršrutas naudoja vidinį
`Promise.all`. Jame vykdomi keli tikslūs `count: "exact"`, du RPC ir papildomi
sąrašų skaitymai.

`counted()` išmeta klaidą vos vienai count užklausai nepavykus. Tada visas
dashboard maršrutas grąžina 500, nors kitos užklausos galėjo būti sėkmingos.

### 3. Dashboard skaičiuoja per gyvą `catalog_items` view

Pagrindinis `/v1/catalog` endpointas jau skaito iš materialized
`catalog_items_read`, tačiau dashboard šiems rodikliams vis dar naudoja gyvą
`catalog_items`:

- bendras katalogo produktų skaičius;
- premium produktų skaičius;
- naujų produktų skaičius;
- produktų žemiau 30 dienų minimumo skaičius;
- produktų be kategorijos skaičius.

Produkcijos `catalog_items` tebėra gyvas view, atliekantis:

- `products`, `sources`, `offers`, `product_categories`, `categories` ir
  `brand_tiers` join;
- kategorijų `array_agg(distinct ...)`;
- grupavimą pagal produktą ir brand tier.

Todėl kiekvienas tikslus count gali iš naujo vykdyti didelę agregavimo užklausą.
Keli tokie count vienu metu konkuruoja dėl tų pačių DB resursų.

### 4. Dashboard apeina egzistuojantį facet cache

Dashboard tiesiogiai kviečia `catalog_category_facets({})`. Produkcijoje ši RPC
pasiekia iki ~7,93 s.

Repozitorijoje jau yra `catalog_facets_cache` ir `catalog_facets_cached`, tačiau
dashboard kategorijų suvestinė jų nenaudoja. Tuščių filtrų kategorijos gali būti
paimtos iš jau paruošto cache, užuot perskaičiuojamos kiekvieno puslapio
atidarymo metu.

### 5. `brand_tier_admin_items` perskaičiuojamas kiekvieną kartą

View kiekvienam produktui vykdo:

```sql
lower(regexp_replace(trim(brand), '\s+', ' ', 'g'))
```

ir tada grupuoja visą `products` lentelę. Yra dalinis indeksas į originalų
`products.brand`, tačiau nėra indekso į normalizuotą išraišką. Be to, view turi
matyti ir neaktyvius produktus, todėl esamas tik aktyviems produktams skirtas
indeksas nepadengia visos užklausos.

Normalioje būsenoje endpointas kartais spėja grįžti su 200, tačiau DB I/O
apkrovos metu priartėja prie 8 s ir tampa nestabilus.

## Read modelio refresh įtaka

Analizės momentu refresh būsena buvo švari:

```text
requested_version = 21
completed_version = 21
last_status = clean
```

Paskutinis realus rebuild truko apie 62,7 s. Loguose taip pat matyti iki maždaug
270 s trunkantys checkpoint'ai ir didelis WAL srautas. Refresh nėra nuolat
užstrigęs, tačiau jo sukelta I/O apkrova padidina interaktyvių užklausų trukmę.

Todėl refresh yra incidentą sustiprinantis veiksnys, bet ne pirminė admin kodo
problema. Net ir be refresh dabartinės užklausos yra pernelyg arti 8 s ribos.

## Kas nėra pagrindinė priežastis

- **CORS:** Pages origin yra leidžiamas Worker konfigūracijoje.
- **JWT ar admin teisės:** narystės užklausos grįžta 200; klaidos nėra 401/403.
- **Cloudflare Worker CPU limitas:** pateiktame įvykyje sunaudota tik 2 ms CPU.
- **Nepritaikytos migracijos:** aktualios read modelio stabilizavimo migracijos
  produkcijoje pritaikytos.
- **Užstrigęs refresh:** analizės metu refresh state buvo `clean`.

## Diagnostikos trūkumai

Worker loge šiuo metu matomas tik nepavykusios HTTP užklausos URL. Dashboard
count klaida praranda užklausos identitetą, nes visos count užklausos eina per tą
patį `counted()` helperį.

Reikėtų loguoti bent:

- endpointą ir loginį užklausos pavadinimą;
- Supabase `code`, `message`, `details` ir `hint`;
- užklausos trukmę;
- ar klaida yra timeout;
- bendrą request/correlation ID.

Tai nepataisys našumo, bet kitą incidentą leis diagnozuoti iš vieno Worker įvykio.

## Nerekomenduojamas vienintelis sprendimas

Vien `statement_timeout` padidinimas gali laikinai sumažinti 500 skaičių, tačiau:

- nepanaikina brangių view ir exact count skenavimų;
- leidžia vienam admin puslapio atidarymui ilgiau laikyti DB resursus;
- apkrovos metu dar labiau padidina užklausų eilę;
- paslepia architektūrinį skirtumą tarp `catalog_items` ir
  `catalog_items_read`.

Timeout didinimas gali būti tik laikina apsauga po užklausų optimizavimo ir su
aiškia stebėsena.

## 1/2/3 etapų eiga

### 1 etapas — greitas stabilizavimas

**Sunkumas:** mažas  
**Įgyvendinamumas:** labai aukštas  
**Nauda:** aukšta ir greita  
**Rizika:** maža

Tikslas — pašalinti dabar matomus timeout ir neleisti vienai klaidai užtemdyti
viso admin puslapio.

Eiga:

1. Dashboard `catalog_items` count užklausas perjungti į
   `catalog_items_read`.
2. `catalog_category_facets({})` pakeisti skaitymu iš
   `catalog_facets_cached({})` arba tiesiai iš tuščių filtrų cache payload.
3. UI pradinį `Promise.all` pakeisti į `Promise.allSettled` arba atskiras panelių
   užklausas, kad brand tier ar dashboard klaida nenumuštų naudotojų ir sync
   valdymo.
4. `counted()` perduoti loginį užklausos pavadinimą ir struktūruotai loguoti
   Supabase klaidą bei trukmę.
5. Pridėti testus, patvirtinančius, kad dashboard nebeskaito
   `catalog_items` ir vienos panelės klaida neužblokuoja kitų.

Priėmimo kriterijai:

- `/v1/admin/dashboard` stabiliai grįžta 200;
- admin puslapis parodo veikiančias paneles net vienam endpointui suklydus;
- vienas puslapio atidarymas nebekviečia nekeshuoto kategorijų agregavimo;
- Worker loge aiškiai matomas nepavykusios DB operacijos pavadinimas.

### 2 etapas — admin užklausų konsolidavimas

**Sunkumas:** vidutinis  
**Įgyvendinamumas:** aukštas  
**Nauda:** labai aukšta  
**Rizika:** vidutinė

Tikslas — sumažinti DB round-trip, tikslių count skaičiavimų ir pasikartojančių
autentifikacijos patikrinimų skaičių.

Eiga:

1. Sukurti vieną `admin_dashboard_stats()` RPC, kuris vienoje DB užklausoje
   grąžina visą dashboard suvestinę iš read modelio ir paprastų lentelių.
2. Nekintančius ar lėtai kintančius rodiklius skaičiuoti vieną kartą, o ne
   atskirais PostgREST `HEAD count=exact` kvietimais.
3. Pradinį admin bootstrap apjungti į vieną endpointą arba du loginius
   endpointus: greita suvestinė ir valdymo sąrašai.
4. Atsisakyti penkių vienu metu atliekamų vienodų `team_members` patikrinimų
   vienam puslapio atidarymui.
5. Pridėti trukmės metrikas ir perspėjimą, kai admin užklausa viršija 2 s.
6. Produkcijoje palyginti p50/p95 ir DB užklausų skaičių prieš bei po pakeitimo.

Priėmimo kriterijai:

- pradinis admin užkrovimas naudoja ne daugiau kaip 1–2 Worker endpointus;
- dashboard suvestinė gaunama viena DB RPC užklausa;
- p95 dashboard trukmė mažesnė nei 2 s;
- vienas admin atidarymas nesukuria šešiolikos lygiagrečių DB užklausų.

### 3 etapas — dedikuotas inkrementinis admin read modelis

**Sunkumas:** didelis  
**Įgyvendinamumas:** vidutinis  
**Nauda:** didžiausia ilguoju laikotarpiu  
**Rizika:** vidutinė–aukšta

Tikslas — atskirti administravimo suvestines nuo interaktyvių gyvų agregavimų ir
užtikrinti stabilumą augant katalogui.

Eiga:

1. Sukurti dedikuotas admin suvestinių lenteles, pavyzdžiui:
   `admin_catalog_stats`, `admin_brand_stats` ir `admin_category_stats`.
2. Brandui saugoti kanoninį `brand_key` kaip realų arba generated stulpelį,
   indeksuoti jį ir nebeskaičiuoti regex normalizavimo kiekviename skaityme.
3. Statistiką atnaujinti inkrementiškai po produktų, pasiūlymų, kategorijų ir
   metadata pasikeitimų arba mažais eilės batch'ais.
4. `brand_tier_admin_items` pakeisti paprastu skaitymu iš paruoštos brandų
   suvestinės.
5. Admin read modelio atnaujinimą versijuoti ir stebėti analogiškai katalogo
   read modeliui, tačiau vengti pilnų didelių rebuild.
6. Palaipsniui pašalinti admin priklausomybę nuo gyvo `catalog_items` view.
7. Prieš perjungimą palyginti seno ir naujo modelio rezultatus produkcijoje ir
   turėti rollback kelią.

Priėmimo kriterijai:

- admin užklausų trukmė beveik nepriklauso nuo `products` lentelės dydžio;
- brand tier sąrašas ir dashboard suvestinė skaitomi be pilno produktų
  grupavimo;
- statistikos atsilieka ne daugiau nei sutartas intervalas;
- katalogo refresh ar checkpoint reikšmingai neveikia admin p95;
- 8 s timeout paliekamas kaip apsauga, o ne tampa normaliu užklausų vykdymo
  biudžetu.

## Rekomenduojama prioritetų seka

Pradėti nuo 1 etapo, nes jis turi geriausią naudos, rizikos ir įgyvendinimo laiko
santykį. Po produkcijos matavimų vykdyti 2 etapą, kuris pašalina pagrindinį
užklausų fan-out. 3 etapą pradėti, jei katalogas toliau auga, admin p95 po 2
etapo išlieka per didelis arba read modelio refresh vis dar sukelia interaktyvių
užklausų degradaciją.
