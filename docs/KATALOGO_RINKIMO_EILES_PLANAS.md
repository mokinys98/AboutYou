# Katalogo rinkimo eilė

Įgyvendintas tęstinis katalogo rinkimas, skirtas dideliam katalogui, kuris netelpa į vieną GitHub Actions darbą. GitHub Actions lieka vykdytoju, o Supabase saugo ciklų, užduočių, lease ir patvirtintų paketų būseną.

## Veikimas

- Cloudflare Worker paleidžia `sync-catalog.yml` kas 15 minučių. Vienas GitHub darbas turi 20 min. avarinį limitą, o rinkiklis dirba iki 10 min.
- Eilė sukuria vieną aktyvų ciklą kiekvienam `sync_target`. Naujas ciklas tam pačiam target'ui sukuriamas ne dažniau nei kartą per 24 valandas.
- `catalog_target_parts` yra versijuotas skaidymo manifestas. Migracija saugiai sukuria po `root` dalį kiekvienam esamam target'ui. Vėlesnė migracija gali pridėti mažesnes kategorijų dalis, nekeisdama pirminio target'o ar jo produkto ryšių.
- Užduotys rezervuojamos atominiu `FOR UPDATE SKIP LOCKED` veiksmu. Lease galioja 3 min. ir darbuotojas jį pratęsia kas 30 s. Pasibaigęs lease grąžina užduotį į eilę; senas žetonas nebegali nieko įrašyti.
- Kiekvienas 200 produktų paketas gauna puslapio numerį ir stabilų produkto ID rinkinio hash. Pakartotas jau patvirtintas paketas grąžina `0` ir nekuria naujų kainos stebėjimų.
- `finish_sync_run(..., 'success', ...)` vykdomas tik užbaigus visas pirminio target'o manifesto dalis. Dalinės ar užblokuotos dalys nesikeičia dingusių prekių skaitiklių.
- 403/429 pristabdo visą šaltinį mažiausiai 60 min. Jei šaltinis grąžina `Retry-After`, naudojama ilgesnė reikšmė. Kitos laikinos klaidos kartojamos po 5, 15 ir 60 min.; nuo penkto bandymo dalis pažymima `blocked`.

Produkciniame eilės režime DOM slinkimo fallback išjungtas. Sugedęs tiesioginis srautas užduotį atideda su diagnostika, todėl lėtas fallback nebeišnaudoja viso darbo limito. Diagnostinė komanda ir atskiras GitHub workflow gali naudoti fallback tyrimui.

## Manifesto plėtimas

Esamos `root` dalys sąmoningai nebuvo spėjamos suskaidyti į 25 konkrečius URL. Prieš pridėdami smulkesnes dalis, patvirtinkite URL diagnostiniu workflow ir įtraukite juos vienoje naujoje migracijoje:

```sql
insert into public.catalog_target_parts (target_id, part_key, url, priority)
values
  ('<target-id>', 'clothing-shirts', 'https://www.aboutyou.lt/c/...', 100),
  ('<target-id>', 'clothing-trousers', 'https://www.aboutyou.lt/c/...', 110);

update public.catalog_target_parts
set enabled = false, updated_at = now()
where target_id = '<target-id>' and part_key = 'root';
```

Išlaikykite pirminio URL prekės ženklo ir kitus filtrus. Viena dalis turėtų turėti iki 5 000 produktų; 15 000 yra tik apsauginė riba. Dalys gali persidengti: produktai deduplikuojami pagal šaltinį ir išorinį produkto ID.

## Diagnostika ir patikra

GitHub Actions workflow **Diagnose catalog stream** neturi DB paslapčių. Paleiskite jį bendrai kategorijai, prekės ženklo filtrui ir Premium kategorijai. Artefakte `events.jsonl` turi būti `category_stream_module_matched`, `initial_network_stream_decoded`, `stream_page_completed` ir žinomas `expectedTotal`.

Tiesioginio srauto aptikimas dabar įtraukia ir `service.grpc.lazy-…` asset modulius. Ankstesnis filtras juos atmesdavo, todėl GitHub rinkiklis pereidavo į lėtą slinkimą.

2026-09-22 „Premium“ apatinių drabužių kategorijos patikra: [GitHub diagnostika](https://github.com/mokinys98/AboutYou/actions/runs/35689457119) grąžino 867 unikalius produktus per 27 papildomus puslapius; srauto `pagination.total` buvo 890, o paskutinis puslapis nebeturėjo `nextState`. Atskiroje Playwright sesijoje svetainės natūralus slinkimas pagrindiniame produktų tinklelyje parodė tuos pačius 867 ID, nė vieno papildomo. Visame puslapyje buvo dar 56 ID atskirame produktų bloke ir viena reklaminė produkto nuoroda; jie nepriklauso pagrindiniam tinkleliui. Todėl 23 skirtumas nėra įrodymas, kad rinkiklis prarado tinklelio prekes. Dabartinis `complete: false` yra konservatyvus, nes eilė reikalauja `collected >= expectedTotal`; prieš keičiant šią taisyklę reikia apibrėžti, kaip saugiai priimti pasibaigusį srautą, kurio deklaruotas bendras kiekis nesutampa su faktiniu tinkleliu.

Vietinis SQL testas `supabase/tests/catalog_collection_queue_test.sql` tikrina lease perėmimą, seno lease atmetimą, idempotentišką puslapio įrašymą ir 60 000 sintetinių produktų ciklą. Jis skirtas tik tuščiai, izoliuotai testinei DB.

## VPS migracija

Pagal projekto `AGENTS.md`, migraciją VPS vykdo savininkas. Jei Pageant dar neturi privataus rakto, paleiskite jį ir slaptafrazę įveskite Pageant lange:

```powershell
Start-Process -FilePath "C:\Program Files\PuTTY\pageant.exe" `
  -ArgumentList '"C:\Users\Auris\Documents\contabo.ppk"'
```

Įkelkite abu migracijos failus. Jei jau pritaikėte pirmąjį, pritaikykite bent antrąjį: jis užtikrina, kad `partial` ar `blocked` ciklas nebus pradėtas iš naujo kas 15 min.

```powershell
& "C:\Program Files\PuTTY\pscp.exe" `
  -agent `
  -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
  ".\supabase\migrations\20260921122000_add_catalog_collection_queue.sql" `
  deploy@169.58.26.120:/tmp/20260921122000_add_catalog_collection_queue.sql

& "C:\Program Files\PuTTY\pscp.exe" `
  -agent `
  -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
  ".\supabase\migrations\20260921130000_limit_catalog_cycle_cadence.sql" `
  deploy@169.58.26.120:/tmp/20260921130000_limit_catalog_cycle_cadence.sql
```

Atidarykite interaktyvią sesiją:

```powershell
& "C:\Program Files\PuTTY\plink.exe" `
  -agent `
  -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
  deploy@169.58.26.120
```

VPS terminale, interaktyviai įvedę `sudo` slaptažodį, vykdykite:

```bash
sudo docker exec -i supabase-db psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d postgres \
  < /tmp/20260921122000_add_catalog_collection_queue.sql

sudo docker exec -i supabase-db psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d postgres \
  < /tmp/20260921130000_limit_catalog_cycle_cadence.sql
```

Po sėkmingo vykdymo patikrinkite:

```sql
select status, count(*)
from public.catalog_collection_tasks
group by status order by status;

select t.label, c.status, c.started_at, c.finished_at, c.error
from public.catalog_sync_cycles c
join public.sync_targets t on t.id = c.target_id
order by c.started_at desc
limit 25;

select s.slug, paused_until, reason
from public.catalog_source_pauses p
join public.sources s on s.id = p.source_id;
```

Tik po sėkmingo vykdymo ir patikros pašalinkite laikiną failą:

```bash
rm -f /tmp/20260921122000_add_catalog_collection_queue.sql
rm -f /tmp/20260921130000_limit_catalog_cycle_cadence.sql
exit
```

## Perdavimo suvestinė 2026-09-23

### Kas atlikta

- Įdiegta katalogo užduočių eilė su ciklais, dalimis, užduočių būsenomis, 3 minučių lease, lease pratęsimu, `FOR UPDATE SKIP LOCKED`, bandymų atidėjimu ir idempotentišku puslapio įrašymu.
- Įdiegtas vienas darbuotojas, kuris per vieną paleidimą dirba iki 10 minučių; GitHub workflow turi 20 minučių avarinį limitą.
- Produkciniame režime DOM slinkimo fallback išjungtas. Tiesioginio srauto klaida užduotį palieka eilėje su diagnostika.
- ABOUT YOU modulio aptikimas pataisytas: `service.grpc.lazy-*` tarpiniai moduliai išskleidžiami iki tikro `service.grpc-*` modulio.
- Diagnostikos workflow saugo `events.jsonl`, `summary.json`, produktus ir pradinės būsenos struktūras; workflow neturi DB paslapčių.
- `sync-catalog.yml` ir staging workflow dabar naudoja `pipefail`, todėl GitHub nebepaslepia `npm` klaidos už žalio veiksmo rezultato.
- Eilės RPC teisės apribotos `service_role`; vieši klientai lentelių skaityti ir keisti negali.

### Migracijos

1. `20260921122000_add_catalog_collection_queue.sql` – sukuria eiles lenteles, RPC ir pradines `root` dalis.
2. `20260921130000_limit_catalog_cycle_cadence.sql` – neleidžia tam pačiam target'ui kurti naujo ciklo dažniau nei kas 24 valandas.
3. `20260922090000_fix_catalog_queue_claim_ambiguity.sql` – pašalina PostgreSQL `42702 target_id is ambiguous` klaidą funkcijoje `claim_catalog_collection_task`.

Savininkas patvirtino trečios migracijos patikrą: `fixed = true`. Remote VPS prie Codex neprieinamas; migracijų vykdymą ir DB būsenos patikrą atlieka savininkas pagal šiame dokumente pateiktas PuTTY komandas.

### Diagnostikos rezultatai

- Calvin Klein filtro paleidimas patvirtino tiesioginį srautą, puslapiavimą ir `expectedTotal: 1785`.
- Bendra „Batai“ kategorija patvirtino tiesioginį srautą ir `expectedTotal: 7398`.
- Premium kategorijos paleidimas rado `expectedTotal: 890`, bet gavo 867 pagrindinio tinklelio produktus. Natūralus svetainės slinkimas parodė tuos pačius 867 ID; kiti puslapio ID priklauso atskiram rekomendacijų blokui ir reklamai. Tai nėra įrodytas rinkiklio praradimas, todėl ši grupė tebėra `complete: false`.

### Produkcinio sync būklė

Po `42702` pataisos darbuotojas pradėjo realiai imti užduotis ir įrašyti produktus. Naujausiame darbe buvo paimta 12 užduočių ir įrašyta 11 162 produktų paketų, taip pat paprašytas skaitymo modelio atnaujinimas.

Dabartinė eilė neužbaigia grupių, kai `collected_count < expected_total`, todėl užduotys lieka `retryable`. Iki 2026-09-24 didelės grupės pasiekdavo `SYNC_MAX_PRODUCTS=5000` ribą, o dalis mažesnių URL baigdavosi keliais produktais žemiau šaltinio deklaruojamo `expectedTotal`. Tai apsaugo nuo klaidingo ciklo užbaigimo, tačiau reiškia, kad grupės kartojamos ir po penkto bandymo gali tapti `blocked`.

### 2026-09-24 mastelio pakeitimai

- Workflow ir queue worker limitas paruoštas kelti iki `SYNC_MAX_PRODUCTS=15000`.
- Pirminis PostgreSQL įrašymo batch mažinamas nuo 200 iki 100 produktų; `57014` atveju lieka adaptyvus skaidymas iki 50 ir 25.
- `sync_targets.expected_total` saugos paskutinį root grupės šaltinio `expectedTotal`; migracija taip pat užpildys esamas grupes iš naujausios root užduoties.
- Admin UI aiškiai rodo, kad realus claim eiliškumas yra ciklo amžius, tada mažesnis grupės prioritetas, tada mažesnis dalies prioritetas.
- Šie pakeitimai pradės veikti tik įkėlus kodą ir pritaikius `20260924073825_persist_catalog_target_expected_total.sql` VPS.

### Git istorija

- `6af37a0` – eilės įgyvendinimas.
- `5efe7ae` – ciklo kadencijos migracijos paruošimas.
- `2291b8e` – tiesioginio `service.grpc.lazy-*` modulio aptikimo pataisa.
- `030fa12`, `98ef8f3` – nepilno srauto diagnostika ir teisingas `direct-stream` režimo raportavimas.
- `4416713` – PostgreSQL claim pataisa ir workflow `pipefail`.
- `0e4edac` – Premium tinklelio ir srauto palyginimo išvada.

Šie katalogo eilės pataisymai šiuo metu yra šakoje `fix/premium-stream-diagnostics`; prieš produkcinį naudojimą juos reikia sujungti į `main` ir paleisti workflow iš `main`.

### Kas liko

1. Sujungti patikrintus pakeitimus į `main`.
2. Peržiūrėti VPS `catalog_collection_tasks` ir `catalog_sync_cycles` būsenas po kelių paleidimų.
3. Suskaidyti dideles `root` dalis pagal tikrą kategorijų hierarchiją; nekeisti URL pagal kainą ar sąrašo poziciją.
4. Atskirai nuspręsti, kaip priimti pasibaigusį srautą, kai svetainės `expectedTotal` neatitinka pagrindinio tinklelio faktinio kiekio. Ši taisyklė negali būti pakeista vien dėl to, kad užduotys greičiau taptų `completed`.
5. Tik po šių patikrų įjungti viso manifesto 15 minučių grafiką ir stebėti 24 valandų našumą.

## Metaduomenų rinkimo pataisa — 2026-09-23

Pataisyta vietinėje `fix/premium-stream-diagnostics` šakoje; produkcinis įdiegimas ir VPS duomenų atsinaujinimas dar nepatvirtinti.

### Nustatyta priežastis

- [Metaduomenų workflow 35803575773](https://github.com/mokinys98/AboutYou/actions/runs/35803575773) apdorojo 3 009 prekes: `payload_ok=0`, `complete=0`, `retryable=3009`, tačiau GitHub rezultatas buvo `success`.
- [Workflow 35819764168](https://github.com/mokinys98/AboutYou/actions/runs/35819764168) jau nepaėmė užduočių (`claimed=0`); suvestinėje buvo 37 549 aktyvios prekės, 1 `complete`, 37 156 `retryable`, 392 `sourceUnavailable`. Vien šis žurnalas neatskleidžia, ar eilė laukia būsimo termino, ar turi `infinity` įrašų.
- Dabartinės aktyvios prekės HTML neturi `ArticleDetailService/GetProductBulk` payload. Svetainė jį gauna asinchronine gRPC užklausa. Senasis darbuotojas naudojo tik HTTP HTML gavimą, todėl negalėjo paimti šių duomenų. Priežastis atkartota viešame šaltinyje be VPS prieigos.
- Administravimo 0 % skaičiuojamas iš aktyvių prekių dabartinės sinchronizacijos `complete` būsenos. „32 927 prekių su metadata“ yra atskiras turimų metaduomenų rodiklis. „53 % kataloge“ taip pat nėra metaduomenų aprėptis. Katalogo srauto neužbaigtumas ir metaduomenų gavimo klaida yra atskiros problemos.

### Pakeitimai

- Darbuotojas atidaro prekės puslapį ir perskaito svetainės natūralų `GetProductBulk` atsakymą. Jį dekoduoja tuo metu puslapio įkeltas `ArticleDetailService` modulis; asset hash nekoduojamas pastoviai. HTML payload kelias išlieka palaikomas.
- Išlaikoma produkto ID ir galutinio URL patikra, schemos kontrolė, visų keturių detalių sekcijų būsenos, 403/429 stabdymas. Atsižvelgiama ir į JavaScript peradresavimą, kai pašalintos prekės pradinis HTTP atsakymas dar yra 200.
- Visas vienos prekės gavimas, įskaitant atsakymo turinį ir dekodavimą, ribojamas 25 sekundėmis; puslapis visada uždaromas. Į raw archyvą neperduodami `basketToken`, `trackingSection`, `trailers`.
- Laikinos / schemos klaidos ir ribojimas nustato exit 1. Tuščia eilė savaime nėra klaida. Kai paimta bent 25 prekių, nėra nė vienos sėkmės ir bent 20 laikinų / schemos klaidų, darbas stabdomas, nelaukiant tūkstančių nesėkmių.
- Klaidų kodai ir skaitikliai matomi žurnale; produkcinis ir staging workflow išsaugo logą 14 dienų ir naudoja `pipefail`.
- Pridėtas `Diagnose product metadata` workflow ir vietinė `diagnose:metadata` komanda be DB paslapčių ar `.env` skaitymo.
- Parserio versija lieka 5: taisomas transportas, o ne žinomų laukų interpretacija. Naujos SQL migracijos šiai pataisai nereikia.

### Patikra ir paleidimas

Vietiniai testai: 138/138; providerio ir sync TypeScript patikra sėkminga. Gyvi šaltinio testai: 3/3 (`32237548`, `32190350`, `15135978`), visais atvejais gauti tinkami payload, ID, nuotraukos, dydžiai ir keturios detalių sekcijų būsenos. Seni gyvų testų URL atnaujinti, nes pirmasis senas produktas jau nukreipia į prekės ženklo puslapį. Katalogo testų harness papildytas po ankstesnio pakeitimo trūkusia tikra `collectStreamItems` funkcija.

Viešo šaltinio diagnostika iš projekto šaknies:

```powershell
npm.cmd run diagnose:metadata -- "https://www.aboutyou.lt/p/vans/sportbaciai-be-auliuko-32237548"
```

Santrauka: `apps/sync/test-results/metadata-diagnostics/summary.json`. Kiekvienam URL tame pačiame kataloge taip pat paliekamas Playwright trace `traces/<nr>.zip`, išvalyta network įvykių laiko juosta santraukoje ir, timeout atveju, `timeout-<nr>.png`. Prekei dingus iš šaltinio, naudokite dabartinį aktyvios prekės URL.

Po kodo sujungimo į workflow naudojamą `main` šaką pirmiausia patikrinkite viešą šaltinį su `Diagnose product metadata`. Savininkas tada gali paleisti `Sync product metadata` su `max_products=50`; tikrinkite `payload_ok`, `complete`, `failure_codes` ir workflow baigtį. Šis produkcinis paleidimas naudoja VPS, todėl Codex jo nevykdė.

Jei `claimed=0`, savininkas gali atlikti šią tik skaitymo patikrą VPS `psql` sesijoje (prisijungimo komandos pateiktos `docs/RINKIMO_DIAGNOSTIKA.md`):

```sql
select status, last_error_code, count(*) as products,
       count(*) filter (where next_attempt_at <= now()) as due_now,
       count(*) filter (where next_attempt_at = 'infinity'::timestamptz) as infinite_wait,
       min(next_attempt_at) as earliest_attempt
from public.product_detail_sync
where product_active
group by status, last_error_code
order by products desc;
```

Jei laikinos klaidos įstrigusios ties `infinity`, jau paruoštos migracijos `20260920190501_recover_transient_metadata_failures.sql` įkėlimo, vykdymo ir patikros komandos yra `docs/RINKIMO_DIAGNOSTIKA.md`. Jos taikymo nelaikome patvirtintu. Būsenų ir parserio versijos masiškai neatstatome; būsimo termino laukiančios užduotys turi būti paimtos pagal esamą kartojimo politiką.
