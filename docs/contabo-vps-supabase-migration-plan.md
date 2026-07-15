# Supabase → Contabo VPS self-hosted migracijos planas

**Statusas:** vykdomasis planas agentams  
**Savininkas:** produkto ir techninis atsakingasis  
**Tikslinė aplinka:** Contabo Cloud VPS 6, ES regionas — 6 vCPU, 12 GB RAM, 200 GB SSD, 2 snapshot'ai  
**Apimtis:** tik dabartinio Supabase projekto perkėlimas į savarankiškai valdomą Supabase Contabo VPS serveryje  
**Ne apimtis:** Cloudflare Pages, Cloudflare Worker, GitHub Actions sinchronizacijos ir Telegram webhook'o perkėlimas į VPS

## 1. Sprendimo santrauka

Migracija yra techniškai pagrįsta: pasirinktas Contabo VPS turi pakankamai pradinės talpos self-hosted Supabase aplinkai ir yra gerokai mažiau ribotas nei dabartinis valdomas planas. Tačiau tai **nėra vien infrastruktūros problema**. Dabartiniai katalogo ir admin dashboard incidentai rodo brangius pilnus read-model atnaujinimus, WAL ir disko spaudimą bei perteklinį admin užklausų fan-out. Vien perkėlus duomenų bazę tie algoritmai neišnyks.

Todėl planas turi du lygiagrečius rezultatus:

1. saugiai perkelti visus Supabase duomenis, Auth, Storage ir susijusią konfigūraciją į Contabo;
2. prieš produkcinį perjungimą įdiegti apsaugas nuo jau matytų timeout, pilno disko ir pasikartojančio refresh ciklo gedimų.

### Sprendimas dėl Cloudflare

Cloudflare lieka savo vietoje:

- Cloudflare Pages toliau aptarnauja Nuxt aplikaciją;
- Cloudflare Worker toliau yra API, JWT tikrinimo, cache, Telegram webhook'o ir GitHub Actions paleidimo sluoksnis;
- GitHub Actions toliau vykdo katalogo ir metadata sinchronizacijas;
- neperkeliame Worker, Pages, cron logikos ar Telegram į Contabo.

Yra tik **minimalūs, neišvengiami integraciniai pakeitimai**:

1. reikės naujo viešo Supabase URL, pvz. **https://supabase.tavo-domenas.lt**, kuris saugiai pasiektų Contabo VPS;
2. Cloudflare Pages, Worker ir GitHub Actions reikės pakeisti Supabase URL ir raktus;
3. per galutinį perjungimą trumpam sustabdomi esami planiniai writer'iai, kad nebūtų dviejų duomenų tiesos šaltinių.

Rekomenduojamas saugiausias būdas yra naujas, atskiras Cloudflare Tunnel iš VPS į Cloudflare. Tai nėra esamų Cloudflare servisų migracija ar perrašymas: jis tik publikuoja naują Supabase hostname'ą, o VPS neturi būti tiesiogiai atvertas internete. Jei nenorima naudoti Tunnel, alternatyva yra Caddy arba Nginx su viešu 443 portu, TLS ir griežta ugniasiene, bet tai turi didesnį origin atakos paviršių.

> Svarbi prielaida: produkciniam perjungimui reikia valdomo domeno Cloudflare zonoje. Vien pages.dev hostname'o neužtenka subdomeniui supabase.tavo-domenas.lt sukurti. Be domeno vis dar galima pradėti VPS diegimą, testinį restore ir našumo testus, tačiau negalima saugiai užbaigti naršyklės Auth ir produkcinio perjungimo.

### Nemokamas hostname variantas

Nuosavas mokamas domenas nėra privalomas produkcijai, tačiau viešam naršyklės Auth būtinas patikimas HTTPS **hostname'as**. Vien tik VPS IP adresas nėra tinkamas: viešai patikimam TLS sertifikatui naudojamas vardas, o ne plikas IP.

Jei nenorima pirkti domeno ar valdyti Cloudflare DNS, galima naudoti nemokamą dinaminio DNS tiekėjo subdomenį, pvz. aboutyou-supabase.duckdns.org:

- vieną kartą susiejamas subdomenis su Contabo VPS IPv4 adresu;
- Caddy tiesiogiai publikuoja tik HTTPS 80/443 ir automatiškai tvarko sertifikatą;
- Caddy persiunčia srautą tik į vidinį Supabase Kong servisą;
- UFW vis tiek uždaro 5432, 6543, 8000 ir Studio; Studio pasiekiamas tik per SSH;
- Cloudflare Pages, Worker ir GitHub Actions gauna šį HTTPS URL, bet jų infrastruktūra nesikeičia.

Tai nemokamas ir mažiau DNS administravimo reikalaujantis kelias, tačiau jis nenaudoja Cloudflare Tunnel: VPS turi turėti viešai atvertus 80 ir 443 portus. Jei vėliau įsigyjamas nuosavas domenas, galima pereiti prie Tunnel be DB migracijos.

## 2. Dabartinė sistema ir tikslinė architektūra

### 2.1. Dabartiniai komponentai

| Komponentas | Dabartinė atsakomybė | Migracijos sprendimas |
|---|---|---|
| Cloudflare Pages / Nuxt | Web UI ir Supabase browser Auth klientas | Paliekamas |
| Cloudflare Worker | /v1 API, JWT/JWKS tikrinimas, service-role DB prieiga, 5 min cache, Telegram, cron dispatch | Paliekamas; keičiami tik Supabase secrets |
| GitHub Actions | Katalogo ir product metadata sinchronizacijos | Paliekamas; keičiami tik Supabase secrets |
| Supabase Platform | Postgres, Auth, Storage, PostgREST, Realtime, funkcijos, RLS, pg_cron | Perkeliamas į Contabo self-hosted Supabase |
| Telegram | Webhook į Worker ir DB outbox | Paliekamas |

### 2.2. Tikslinė topologija

~~~text
Naršyklė
  │
  ├── Cloudflare Pages ──────────────── Nuxt aplikacija
  │       │
  │       ├── Cloudflare Worker ─────── /v1 API, cache, Telegram, GitHub dispatch
  │       │       │
  │       │       └── https://supabase.<domenas> ─┐
  │       │                                        │
  │       └── https://supabase.<domenas> ──────────┤
  │                                                │
GitHub Actions ────────────────────────────────────┤
                                                   ▼
                                        Cloudflare Tunnel (outbound)
                                                   │
                                                   ▼
                                      Contabo VPS / Docker network
                                      ├── Kong API gateway
                                      ├── Supabase Auth
                                      ├── PostgREST / Realtime
                                      ├── Storage
                                      ├── Postgres + pg_cron
                                      └── Studio (tik per Access arba SSH)
~~~

Viešai pasiekiamas turi būti tik Supabase API hostname'as per HTTPS. PostgreSQL, connection pooler ir Studio neturi būti atviri tiesiogiai:

- draudžiami vieši 5432, 6543, 8000 ir Studio portai;
- SSH pradžioje leidžiamas tik administratoriaus IP, vėliau pageidautina per Cloudflare Access arba VPN;
- Studio gauna atskirą hostname'ą ir Cloudflare Access politiką arba naudojamas per SSH tunnel;
- Docker Postgres, Kong ir Storage duomenys laikomi persistent volume'uose, ne ephemeral konteineriuose.

## 3. Esama būklė ir problemos, kurių migracija privalo neišplauti

### 3.1. Katalogo 500 incidentas

Užfiksuotas GET /v1/catalog atsakymas 500 turėjo maždaug 3 ms Worker CPU ir apie 8,8 s wall time. Tai labiau atitinka laukimą į upstream Supabase/Postgres, o ne paties Cloudflare Worker CPU problemą. Tai dar nėra galutinė priežasties diagnozė, todėl prieš migraciją būtina išsaugoti:

- Supabase/Postgres klaidų ir disko metrikas;
- aktyvias ilgas užklausas ir lock'us;
- pg_cron job run istoriją;
- refresh būseną ir paskutinio nesėkmingo refresh priežastį;
- dabartinį laisvą diską, WAL bei temp failų elgseną.

Migracija neturi būti vykdoma kaip aklas avarinis fix'as. Pirmiausia daromas source backup ir diagnostinis baseline; tik po to vyksta rehearsal aplinkoje.

### 3.2. Žinomi read-model ir admin rizikos signalai

Esama dokumentacija fiksuoja šias aplinkybes:

| Signalas | Pasekmė be korekcijos |
|---|---|
| Pilni materialized view katalogo ir facetų refresh'ai | daug I/O, WAL, checkpoint ir laikino disko spaudimo |
| Refresh būklė kas 5 min. bando vėl po gedimo be aiškaus backoff | galima retry storm ir nuolatinė degradacija |
| Admin dashboard anksčiau darė daug lygiagrečių DB užklausų | 8 s statement timeout, 500 ir lėtas UI |
| brand tier admin užklausa vis dar turėjo lėtų outlier'ių | vien VPS resursų padidinimas negarantuoja gero p95 |
| Tikslas – apie 250 000 produktų | apkrova nėra saugiai laikoma tiesine nuo dabartinio masto |

Jau yra lokalūs optimizavimo pakeitimai į cached read model ir Promise.allSettled, tačiau prieš cutover būtina patikrinti, ar jie realiai yra produkcijoje. Nė vienas dokumentas neturi būti laikomas įrodymu, kad deploy jau atliktas.

### 3.3. Dabartinės duomenų priklausomybės

Perkeliama ne tik lentelės:

- Postgres schemos, duomenys, rolės, grants, funkcijos, triggeriai, indeksai, RLS ir Auth vartotojai;
- materialized views: catalog_items_read, catalog_item_facet_values_read ir facetų cache;
- pg_cron refresh ir istorijos valymo job'ai;
- Storage bucket'ų metaduomenys ir jų fiziniai objektai;
- Auth konfigūracija, SMTP, redirect allow-list ir public sign-up politika;
- database-backed Telegram outbox, watchlist, alert, sync ir diagnostikos duomenys.

Privačiuose bucket'uose yra mažiausiai:

| Bucket | Turinys | Kritiškumas |
|---|---|---|
| sync-debug | gzip diagnostiniai HTML artefaktai | reikalinga incidentų analizė |
| sync-raw | sampled ir blocked-schema raw API payload'ai | reikalinga produkto metadata ir debug istorija |

SQL dump perkelia bucket metaduomenis, bet **ne pačius Storage objektų baitus**. Jie kopijuojami atskiru veiksmu ir verifikuojami pagal bucket, kelią, objektų skaičių, baitus ir atrinktus checksum.

## 4. Tikslinės paslaugos resursai ir SLO

### 4.1. Contabo VPS 6 tinkamumas

Pasirinktas 6 vCPU / 12 GB RAM / 200 GB SSD VPS yra tinkamas startinis produkcinis dydis self-hosted Supabase šiam projektui. Oficialus self-hosted Supabase minimumas yra mažesnis, tačiau šis planas yra arčiau rekomenduojamo 4+ CPU, 8+ GB RAM, 80+ GB SSD lygio ir palieka rezervą.

Tai vis tiek yra vienas serveris:

- nėra automatinio HA/failover;
- planiniai darbai, DB ir Storage konkuruos dėl to paties disko;
- Contabo snapshot nėra pilnavertė atsarginė kopija;
- 200 GB negalima laikyti pilnu laisvu plotu: jį dalins DB, WAL, Docker image'ai, Storage, backup staging ir logai.

### 4.2. Pradiniai saugos limitai

| Metrika | Įspėjimas | Kritinis veiksmas |
|---|---:|---|
| VPS diskas | 70 % užpildyta | 80 % – incidentas; 85 % – stabdyti sync ir refresh iki išvalymo |
| Laisva vieta po didžiausio test refresh | mažiau nei 60 GB | produkcinis go/no-go neigiamas |
| Refresh trukmė | p95 daugiau nei 45 s | optimizuoti prieš automatinį režimą |
| Vieno refresh maksimumas | daugiau nei 90 s | neįjungti periodinio pilno refresh be papildomo sprendimo |
| Refresh būsena dirty | daugiau nei 10 min | perspėjimas ir žmogaus patikra |
| API 5xx | daugiau nei 1 % per 5 min | incidentas |
| Backup amžius | daugiau nei 26 h | incidentas |
| Nehealthy konteineris | daugiau nei 2 min | incidentas |

Prie 250 000 produktų svarbiausia nėra vien CPU. Prioritetas yra write amplification, WAL, materialized-view strategija, indeksai, refresh serializavimas ir pakankamas diskas. Jei 250k load test nepasiekia šių ribų, automatinio pilno read-model refresh negalima laikyti priimtinu sprendimu; reikia pereiti į inkrementinį arba griežtai batch'intą modelį.

## 5. Apimtis, ribos ir nekintamos taisyklės

### Į apimtį įeina

- Docker pagrindu diegiamas, versijomis prisegtas self-hosted Supabase;
- Source-to-target Postgres, Auth ir Storage perkėlimas;
- Auth / SMTP / redirect / RLS / API raktų konfigūracija;
- Supabase URL ir raktų pakeitimas Pages, Worker ir GitHub Actions;
- backup, restore testas, monitoringas, incidentų runbook;
- refresh apsaugos, load test ir produkcinis cutover.

### Sąmoningai neįeina

- Cloudflare Pages perkėlimas į VPS;
- Cloudflare Worker perrašymas ar perkėlimas į kitą runtime;
- GitHub Actions migracija į VPS cron;
- Telegram webhook hostname'o keitimas;
- naujų produkto funkcijų kūrimas migracijos metu;
- nepatvirtintas schemos ar business logikos perprojektavimas.

### Nekintamos taisyklės

1. Nėra dual-write periodo. Vienu metu tik vienas Supabase yra write source of truth.
2. Production secret'ai niekada nepatenka į Git, dokumentą, screenshot ar Pages public runtime config.
3. SUPABASE_SERVICE_ROLE_KEY lieka tik Worker, GitHub Actions ir patikimoje serverio aplinkoje. Jis niekada nepatenka į Nuxt bundle.
4. Nenaudojamas Docker image tag'as latest. Compose, Supabase release ir Postgres versija yra prisegami ir įrašomi į change log.
5. Istorinės repo migracijos nėra aklai vykdomos ant jau atkurto dump'o.
6. Joks agentas neperjungia produkcijos be išvardytų go/no-go įrodymų ir releaso savininko patvirtinimo.

## 6. Agentų darbų paketai ir atsakomybė

| ID | Savininkas | Darbo paketas | Priklausomybė | Baigties įrodymas |
|---|---|---|---|---|
| M0 | Release / product owner | sprendimų žurnalas, freeze langas, rollback sprendimas | nėra | patvirtintas cutover langas ir kontaktai |
| M1 | Platform / SRE agentas | Contabo hardening, Docker, persistent diskai, Tunnel, backup ir monitoring | M0 | staging Supabase sveikas ir neeksponuoja DB |
| M2 | DB migracijos agentas | source inventory, dump, restore rehearsal, Storage kopija, parity | M1 | pasirašytas source–target palyginimas |
| M3 | DB performance agentas | pg_cron, refresh circuit breaker, 250k testas, admin SQL benchmark | M2 | SLO įrodymai arba aiškus blokatorius |
| M4 | Aplikacijos / integracijų agentas | Auth, SMTP, redirect, Cloudflare/GitHub secret perjungimas | M1 ir M2 | end-to-end testai staging'e |
| M5 | QA / release agentas | canary, cutover, 24 h stebėjimas, rollback valdymas | M0–M4 | checklist, audit trail, post-cutover ataskaita |

### M0 – valdymas ir sprendimai

- Susitarti dėl 2–4 val. mažos rizikos cutover lango ir 24 val. sustiprinto stebėjimo.
- Nustatyti vieną release savininką, kuris vienintelis leidžia eiti per go/no-go vartus.
- Sutarti RPO ne daugiau kaip 24 h, RTO ne daugiau kaip 4 h, ir rollback langą.
- Užfiksuoti, kas turi prieigą prie Contabo, Cloudflare, GitHub ir source Supabase.
- Prieš cutover paskelbti rašymo freeze taisyklę: jokių manual sync, admin mutacijų ar papildomų cron.

### M1 – platforma ir sauga

- Sukurti Ubuntu LTS VPS, atnaujinti OS, sukurti ne-root administratorių ir SSH key-only prieigą.
- Įdiegti Docker Engine ir Compose plugin; persistent data laikyti konkrečiame mount'e, kurio pakanka 200 GB diske.
- Įdiegti prisegtą self-hosted Supabase release iš oficialaus šaltinio. Pirminio diegimo metu neįjungti papildomų Logs & Analytics servisų, jei jie nereikalingi.
- Sukurti atskirą production .env už Git ribų, su mažiausiai teisėmis ir failo prieiga tik administratoriui.
- Sukurti atskirą Cloudflare Tunnel ir du ingress:
  - supabase.<domenas> → Kong API gateway;
  - studio.<domenas> → Studio, apsaugotas Cloudflare Access.
- UFW / cloud firewall: deny by default; nepalikti viešų Postgres, pooler, Kong ar Studio portų.
- Įdiegti Docker log rotation, disk usage, konteinerių health ir host metrikas.
- Įdiegti šifruotus, off-host backup į R2 arba kitą nepriklausomą storage su retention ir restore procedūra.

### M2 – duomenų perkėlimas

- Surinkti source versijų, extensions, cron, lentelių, bucket'ų ir dydžių baseline.
- Pilnai atlikti rehearsal į staging Contabo stack, ne produkciniame target.
- Perkelti roles, schema ir data oficialiu dump/restore metodu.
- Atskirai kopijuoti sync-debug ir sync-raw Storage objektus.
- Palyginti ne tik row counts, bet ir funkcijas, policy, triggerius, grants, Auth vartotojus, bucket metaduomenis bei fizinius objektus.
- Parengti final delta procedūrą ir įrodyti, kad ji veikia per rehearsal.

### M3 – našumas ir atsparumas

- Patikrinti, kad pg_cron tikrai veikia target Postgres image'e, bet iki testų jo job'ai yra išjungti.
- Įdiegti refresh circuit breaker: po klaidos job'as neturi iš naujo agresyviai bandyti kas 5 minutes.
- Išmatuoti catalog, facets ir admin dashboard p50/p95/p99; išsaugoti explain plan svarbiausioms lėtoms užklausoms.
- Po restore atlikti VACUUM ANALYZE pagal patvirtintą procedūrą.
- Paleisti bent 250k produktų reprezentatyvų load test arba aiškiai dokumentuoti, kodėl tai dar negalima ir kas blokuoja produkcinį mastelį.
- Patikrinti, kad nėra persidengiančių catalog sync, metadata sync ir catalog read-model refresh vykdymų.

### M4 – aplikacija ir išorinės integracijos

- Nustatyti naują public Supabase URL kaip canonical Auth issuer ir API URL.
- Sugeneruoti naujus self-hosted JWT/API raktus saugiai; senų tokenų nebandyti išsaugoti.
- Supabase Auth sukonfigūruoti Site URL, callback, invite ir magic-link redirect allow-list.
- Suvesti ir ištestuoti SMTP. Vieša registracija išlieka išjungta.
- Staging'e pakeisti:
  - Cloudflare Worker secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY;
  - Cloudflare Pages build env: NUXT_PUBLIC_SUPABASE_URL, NUXT_PUBLIC_SUPABASE_ANON_KEY;
  - GitHub Actions secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY;
  - vietinius operacinius .env, jei jie naudojami.
- Nekeisti ALLOWED_ORIGIN ir WEB_APP_URL, jei Pages hostname'as nesikeičia.
- Patikrinti Worker JWKS parsisiuntimą iš naujo URL ir issuer tikrinimą.

### M5 – kokybė ir release

- Vykdyti test matrix iš šio dokumento.
- Sustabdyti tik esamus writer scheduler'ius final sync langui.
- Daryti canary, tada perjungimą, tada 24 h aktyvų monitoringą.
- Jei kriterijai neatitinka, grįžti į rollback; nesiimti tyliai taisyti produkcijoje be šviežio backup.

## 7. Fazių planas

### 0 fazė – source stabilizavimas ir inventorizacija

**Tikslas:** neįnešti papildomos rizikos į jau nestabilią source aplinką.

1. Išsaugoti source incidentų metrikas ir error logus.
2. Užfiksuoti dabartinį DB dydį, diską, didžiausias lenteles, didžiausius Storage objektus ir WAL elgseną.
3. Užfiksuoti tikslias source Postgres ir Supabase versijas.
4. Užfiksuoti visus extensions, roles, cron job'us, active/failed refresh būsenas.
5. Auditinti supabase_migrations.schema_migrations ledger.
6. Patikrinti custom SMTP, redirect URL, OAuth tiekėjus, jei jie aktyvūs, ir Storage konfigūraciją.
7. Sukurti pilną šifruotą source backup prieš bet kokias produkcines modifikacijas.

**Stop vartai:** jei source neturi atkuramo backup arba nėra pakankamai teisių dump'ui, migracija nestartuojama.

### 1 fazė – Contabo platformos paruošimas

**Tikslas:** gauti saugų staging target be viešo DB.

1. Įdiegti VPS ir OS hardening.
2. Sukurti Docker network ir persistent volumes.
3. Įdiegti prisegtą Supabase stack versiją; pasirinkti Postgres versiją tik palyginus su source.
4. Įdiegti Tunnel, hostname'us ir TLS per Cloudflare.
5. Patikrinti iš išorės, kad vieši 5432, 6543 ir Studio nėra prieinami.
6. Įdiegti off-host backup, monitoringą bei log rotation.
7. Parengti atskirą staging hostname'ą, pvz. supabase-staging.<domenas>.

**Stop vartai:** jei Studio/DB prieinami viešai, persistent volume nėra patikrintas arba backup nepasiekia off-host vietos, į 2 fazę neinama.

### 2 fazė – pirmas restore rehearsal

**Tikslas:** įrodyti, kad pilna kopija atkuriama be produkcinio poveikio.

1. Vykdyti oficialų roles/schema/data dump į šifruotą operacinę vietą.
2. Atkurti į staging target.
3. Persiųsti Storage objektus per administracinį API arba patikrintą transfer įrankį; išsaugoti bucket, object key, MIME type, cache-control ir private/public režimą.
4. Nelyginti vien tik SQL storage.objects lentele – patikrinti fizinius objektus.
5. Išjungti imported arba ranka sukurtus cron job'us, kol nebaigtas performance testas.
6. Atlikti parity ataskaitą.

### 3 fazė – funkcijų ir atsparumo testas

**Tikslas:** patikrinti, kad self-hosted aplinka palaiko būtent šios aplikacijos elgseną.

1. Įjungti testinį SMTP ir patikrinti login, magic link, invite, logout bei priverstinį re-login.
2. Worker testuoja naujo Supabase Auth JWKS ir issuer.
3. Testuoti katalogą, filtrus, facets, cursor pagination, watchlist ir cache izoliaciją.
4. Testuoti product details, price history, raw debug artefaktus, admin dashboard, users, brand tiers, sync target CRUD ir sync runs.
5. Testuoti Telegram /start, /status, profile linking ir testinį alert.
6. Paleisti 50 produktų metadata canary, palaukti controlled read-model refresh ir stebėti diską/WAL.
7. Testuoti 250k lygio scenarijų bei admin užklausų konkurenciją.
8. Įrodyti backup restore į disposable environment.

### 4 fazė – produkcinio cutover rehearsal

**Tikslas:** išmatuoti realią perjungimo trukmę, nebandant pirmą kartą produkcijoje.

1. Imituoti writer freeze.
2. Padaryti final delta dump į staging target.
3. Vykdyti visus config pakeitimus iš runbook'o.
4. Išmatuoti DNS/Tunnel, Worker secret deploy, Pages rebuild ir GitHub secret atnaujinimo laiką.
5. Patikrinti, ar tokia pati procedūra telpa į sutartą langą ir rollback vis dar aiškus.

### 5 fazė – produkcinis cutover

Išsamus seka pateikiama 12 skyriuje. Cutover vykdomas tik po formalaus go/no-go.

### 6 fazė – stabilizavimas

- 24 h aktyvus stebėjimas su atsakingu žmogumi;
- source Supabase laikomas rollback-only ir be naujų writer'ių;
- po 7 dienų peržiūrimos metrikos, backup ir incidentai;
- tik po sutarto rollback periodo sprendžiama dėl seno projekto išjungimo.

## 8. Duomenų migracijos metodas

### 8.1. Versijų ir schemos taisyklė

Pirma nustatoma source Postgres versija ir exact self-hosted Supabase release. Self-hosted numatytos Postgres versijos laikui bėgant kinta; negalima automatiškai manyti, kad naujausia versija bus saugi. Target versija parenkama pagal suderinamumą ir pilno rehearsal rezultatą.

Repo turi istorinių migracijų su dubliuotais version prefix. Todėl šios migracijos source of truth yra official roles/schema/data dump, o ne aklas visų istorinių SQL failų perleidimas ant restore rezultato. Po migracijos reikia atskiro sprendimo dėl švaraus future migration baseline.

### 8.2. Oficialaus dump / restore šablonas

Komandos vykdomos tik saugioje administracinėje mašinoje arba užrakintame VPS kataloge. Kintamieji ir dump'ai nepatenka į repozitoriją.

~~~bash
supabase db dump --db-url "$SOURCE_DATABASE_URL" -f roles.sql --role-only
supabase db dump --db-url "$SOURCE_DATABASE_URL" -f schema.sql
supabase db dump --db-url "$SOURCE_DATABASE_URL" -f data.sql --use-copy --data-only
~~~

~~~bash
psql --single-transaction --variable ON_ERROR_STOP=1 --file roles.sql --file schema.sql --command 'SET session_replication_role = replica' --file data.sql --dbname "$TARGET_DATABASE_URL"
~~~

Prieš production restore DB agentas privalo rehearsal'e įrodyti:

- kad target user turi reikiamas teises roles/schema atkūrimui;
- kad extensions ir jų versijos suderinamos;
- kad schema restore neturi klaidų;
- kad target duomenų bazė švari ir cron neįjungiamas per anksti;
- kad dideli dump failai netempiami į nepakankamą VPS diską be atskiro planavimo.

### 8.3. Source baseline SQL

Šios užklausos yra audito pradžia; rezultatą išsaugoti prie release artefaktų be secret'ų.

~~~sql
SHOW server_version;
SELECT extname, extversion FROM pg_extension ORDER BY extname;
SELECT jobid, jobname, schedule, active FROM cron.job ORDER BY jobid;
SELECT pid, usename, state, wait_event_type, now() - query_start AS duration, left(query, 300) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY query_start;
~~~

~~~sql
SELECT 'auth.users' AS entity, count(*) AS rows FROM auth.users
UNION ALL SELECT 'public.products', count(*) FROM public.products
UNION ALL SELECT 'public.offers', count(*) FROM public.offers
UNION ALL SELECT 'public.catalog_items_read', count(*) FROM public.catalog_items_read
UNION ALL SELECT 'public.catalog_item_facet_values_read', count(*) FROM public.catalog_item_facet_values_read
UNION ALL SELECT 'public.team_members', count(*) FROM public.team_members;
~~~

~~~sql
SELECT bucket_id, count(*) AS objects,
       sum(coalesce((metadata ->> 'size')::bigint, 0)) AS stated_bytes
FROM storage.objects
GROUP BY bucket_id
ORDER BY bucket_id;
~~~

Jei source incidento metu šios užklausos pačios kelia riziką, jos vykdomos kontroliuojamu laiku ir priderinamos prie faktinės schemos. Jokių sunkių full refresh ar ANALYZE komandų nereikia paleisti aklai incidento metu.

### 8.4. Storage kopijavimo ir parity taisyklė

1. Išgauti source bucket ir objektų manifestą: bucket, key, size, checksum arba ETag, content type, cache-control, last modified.
2. Perkelti objektus į atitinkamus self-hosted bucket'us su service-level prieiga.
3. Patikrinti tikslų objektų skaičių ir bendrą baitų kiekį kiekvienam bucket'ui.
4. Patikrinti bent 100 atsitiktinių objektų ir visus žinomus kritinius artefaktus checksum arba turinio hash'u.
5. Testuoti private bucket neautorizuotą prieigą – ji turi būti atmesta.
6. Tik po parity pasirašymo galima šalinti source Storage priklausomybę.

## 9. Self-hosted Supabase konfigūracijos reikalavimai

### 9.1. Konfigūracija, kuri turi būti nauja

| Sritis | Reikalavimas |
|---|---|
| Public URL | https://supabase.<domenas>; jis turi sutapti Auth issuer, external API URL ir Worker JWKS keliui |
| API/JWT raktai | sugeneruoti nauji, saugiai saugomi; seni session JWT tampa negaliojantys |
| Auth | Site URL, redirect allow-list, email template URL ir public sign-up taisyklės |
| SMTP | patvirtintas siuntėjas ir testinis laiškas; nepalikti development SMTP |
| DB | stiprus naujas password, tik private Docker network, no public port |
| Storage | persistent backend, bucket policy ir backup planas |
| Compose | prisegtos versijos, persistent volumes, restart policy, health checks |
| Studio | atskiras private / Access-protected endpoint, ne viešas |

### 9.2. Cloudflare, Pages ir GitHub tik minimalus konfigūravimas

| Vieta | Keičiamas parametras | Pastaba |
|---|---|---|
| Cloudflare Tunnel / DNS | naujas supabase hostname | nauja integracija, ne esamų servisų migracija |
| Cloudflare Worker secret | SUPABASE_URL | naujas canonical HTTPS URL |
| Cloudflare Worker secret | SUPABASE_SERVICE_ROLE_KEY | naujas server-only raktas |
| Cloudflare Pages build env | NUXT_PUBLIC_SUPABASE_URL | naujas URL; po pakeitimo būtinas rebuild/deploy |
| Cloudflare Pages build env | NUXT_PUBLIC_SUPABASE_ANON_KEY | tik naujas viešas anon/publishable raktas |
| GitHub Actions secret | SUPABASE_URL | naujas URL |
| GitHub Actions secret | SUPABASE_SERVICE_ROLE_KEY | naujas server-only raktas |

Kas sąmoningai **nesikeičia**, jei UI ir Worker hostname'ai lieka tie patys:

- Worker route'ai ir API kontraktas;
- ALLOWED_ORIGIN;
- WEB_APP_URL;
- Worker cron grafikai;
- GitHub Actions workflow logika ir concurrency grupės;
- Telegram webhook URL ir bot token'ai.

Per cutover Cloudflare cron gali būti laikinai išjungtas tik todėl, kad katalogo ir metadata sync nesukurtų duomenų pakeitimų source ir target aplinkose vienu metu. Po validacijos jis vėl lieka vienintelis GitHub workflow paleidėjas; naujo VPS cron šiems darbams nekuriame.

### 9.3. Auth pasekmė vartotojams

Atkurus auth.users, seni valdomo Supabase JWT nebetinka su naujais self-hosted raktais ir issuer. Reikalingas aiškus komunikacinis faktas: visi vartotojai turės prisijungti iš naujo. Tai nėra duomenų praradimas.

Prieš cutover testuojama:

- password login;
- magic link;
- invite priėmimas;
- PKCE callback;
- logout ir session refresh;
- admin team_members autorizacija;
- Worker JWT tikrinimas per naują JWKS endpoint.

## 10. Patikimumo pataisos, kurios yra kritinis kelias

### 10.1. Refresh circuit breaker

Esamas kas-5-minučių refresh mechanizmas turi išlaikyti dirty būseną po klaidos, bet jis negali aklai kartoti brangaus darbo be cooldown. M3 agentas turi suprojektuoti ir ištestuoti bent šiuos elgesius:

- fiksuoti paskutinės klaidos laiką ir priežastį;
- eksponentinis arba aiškiai nustatytas backoff;
- maksimalus nesėkmių skaičius, po kurio job'as sustabdomas ir siunčiamas alert;
- rankinis saugus enable/disable runbook;
- advisory lock arba kitas įrodytas būdas neleisti persidengiančių refresh;
- aiškus alert, jei refresh_state dirty ilgiau nei 10 min.

Kol tai neįdiegta ir 250k teste neįrodyta, automatinis pilnas refresh yra sąmoningas produkcinis rizikos priėmimas, ne techninis užbaigimas.

### 10.2. pg_cron kontrolė

Restored target neturi pradėti vykdyti scheduler'ių netikėtai. Iš pradžių job'ai yra inactive. Tik po performance ir integracinių testų įjungiami tik šie žinomi job'ai:

| Job name | Grafikas | Paskirtis |
|---|---|---|
| catalog-read-model-refresh | kas 5 min. | kviečia process_catalog_items_read_refresh() |
| catalog-read-model-refresh-history-cleanup | 03:15 kasdien | valo cron.job_run_details istoriją |

Prieš įjungimą tikrinama cron.job lentelė ir įsitikinama, kad nėra dublikatų ar senų netikėtų job'ų.

### 10.3. Admin dashboard

Migracija negali būti uždaryta tik katalogo 200 atsakymu. Dashboard testas turi įrodyti:

- critical counts skaitomi iš read model, ne brangaus live catalog_items view;
- endpoint'ų klaidos nepradanginamos ir UI netampa amžinu loading;
- lėtos brand tier užklausos turi benchmark ir planą;
- p95 yra mažesnis už suderintą ribą; rekomenduojama pradžia – mažiau nei 2 s;
- nėra 8 s Authenticator/PostgREST statement timeout.

## 11. Backup, recovery ir observability

### 11.1. Backup politika

Contabo snapshot yra patogus greitam VPS atstatymui, bet neužtenka database recovery planui. Reikalinga:

- kasdienis šifruotas roles/schema/data dump į off-host saugyklą;
- Storage manifest ir objektų backup arba patikimai versijuotas external object storage;
- Compose config ir non-secret recovery dokumentacija;
- atskiras secrets recovery procesas, saugomas password manager'yje;
- retention, pvz. 7 daily + 4 weekly + 3 monthly, jei jis atitinka faktinį kainos ir duomenų poreikį;
- prieš go-live įrodytas restore į disposable environment;
- kas ketvirtį pakartojamas restore drill.

### 11.2. Minimalus monitoringas

| Signalas | Reakcija |
|---|---|
| Diskas >70 % | įspėjimas, patikrinti WAL, Docker logus ir Storage augimą |
| Diskas >80 % | incidentas; sustabdyti neesminius writer'ius ir planinius refresh |
| Diskas >85 % | nebekurti naujų sync / refresh, išlaisvinti vietą pagal runbook |
| Backup >26 h senumo | incidentas; neplanuoti deploy kol nėra šviežio backup |
| DB / Auth / Storage container unhealthy | tikrinti per 2 min., eskaluoti |
| API 5xx >1 % per 5 min. | tikrinti Worker → Supabase latency ir DB activity |
| Refresh klaida ar dirty >10 min. | sustabdyti retry storm, tirti paskutinį error |
| Refresh >90 s arba WAL šuolis | neplėsti batch ir analizuoti planą |
| Docker logų augimas | log rotation / disk cleanup pagal patvirtintą runbook |

Alertai turi pasiekti bent vieną realų operacinį kanalą (pvz. Telegram arba el. paštą), ne tik likti serveryje.

## 12. Produkcinio cutover runbook

### T-7 iki T-1 diena

- Užbaigtas rehearsal ir pasirašyta parity ataskaita.
- Patvirtinti target URL, Tunnel, SMTP, backup restore ir monitoringas.
- Paruoštas, bet dar neaktyvus Cloudflare Pages build / Worker secret / GitHub secrets pakeitimų sąrašas.
- Įrodyta, kad target cron job'ai aktyvuojami tik sąmoningai.
- Išsiųsta žinutė, kad reikės prisijungti iš naujo.
- Patvirtintas rollback savininkas ir maksimalus sprendimo laikas.

### T0 – įšaldymas

1. Paskelbti maintenance window.
2. Sustabdyti Cloudflare Worker cron dispatch, kad neprasidėtų nauji GitHub sync.
3. Patikrinti ir leisti užsibaigti jau vykstantiems GitHub Actions workflow; nepalikti jų nutrauktų pusiau be būsenos patikros.
4. Sustabdyti admin/manual write operacijas pagal patvirtintą sąrašą.
5. Patikrinti, kad source nėra aktyvaus catalog / metadata sync ar read-model refresh.
6. Padaryti final source dump ir final Storage delta manifestą.

### T0 – atstatymas ir validacija

1. Restore final roles/schema/data į jau patikrintą production target.
2. Perkelti final Storage delta.
3. Paleisti parity queries ir objektų manifest palyginimą.
4. Įjungti tik patikrintus pg_cron job'us.
5. Patikrinti diską ir vieną controlled refresh; neleistina pradėti pilno nekontroliuojamo replay.
6. Patikrinti login, Worker JWKS, /health, katalogą, filtrus, admin ir vieną mock/canary sync.

### T0 – konfigūracijos perjungimas

1. Aktyvuoti Cloudflare Worker naujus SUPABASE_URL ir SUPABASE_SERVICE_ROLE_KEY secret'us ir deploy'inti Worker pagal įprastą procesą.
2. Pakeisti GitHub Actions du secret'us.
3. Pakeisti Pages public URL/key ir padaryti naują Pages build/deploy.
4. Išvalyti tik tas Cloudflare cache vietas, kurių invalidacija būtina naujai auth/data būsenai; neperrašyti Worker logikos.
5. Paleisti smoke testus iš anoniminės naršyklės ir admin paskyros.
6. Tik tada vėl įjungti Cloudflare cron dispatch.

### T+0 iki T+24 val.

- Pirmas katalogo sync ir metadata sync stebimi aktyviai.
- Tikrinami diskas, WAL, API 5xx, cron job run details, refresh trukmė, backup ir Telegram alertai.
- Source išlieka rollback-only: jame negali atsirasti nauji production write'ai.
- Jei bet kuris go/no-go kriterijus sulaužomas, sprendimas priimamas per nustatytą rollback laiką.

## 13. Go / no-go kriterijai

### Būtini GO kriterijai

- [ ] Target konteineriai healthy, volumes persistent ir DB nepasiekiamas viešai.
- [ ] Išbandytas off-host backup restore.
- [ ] Roles, schema, data, RLS, funkcijos, triggeriai, grants, extensions ir auth.users palyginti be nepaaiškintų skirtumų.
- [ ] sync-debug ir sync-raw objektų count, bytes ir atrinkti hash'ai sutampa.
- [ ] Tik du numatyti pg_cron job'ai, be dublikatų; jų būsena kontroliuojama.
- [ ] Password, magic link, invite, PKCE, logout ir priverstinis re-login veikia.
- [ ] Naują JWT Worker validuoja per naują JWKS endpoint.
- [ ] Katalogas, filtrai, facets, pagination, product detail, watchlist ir admin funkcijos veikia.
- [ ] 50 produktų canary metadata sync ir read-model refresh praeina be timeout ar disk pressure.
- [ ] 250k masto testas atitinka sutartus SLO arba yra aiškiai patvirtinta mažesnė produkcinė riba su tolimesniu planu.
- [ ] Po didžiausio test refresh lieka ne mažiau kaip 60 GB laisvo disko.
- [ ] Dashboard p95 neviršija 2 s ir nėra 8 s timeout / 500 per stebėjimo langą.
- [ ] GitHub Actions ir Cloudflare cron užduotys nesidubliuoja.

### Automatiniai NO-GO

- nėra patikrinto restore;
- neaiški source–target duomenų ar Storage paritetas;
- target turi viešą DB arba Studio be Access;
- nėra veikiantis SMTP/Auth redirect;
- nepatikrinta pg_cron arba refresh gali retry'inti kas 5 min. po klaidos;
- diskas po testo mažesnis nei 60 GB;
- esama source incidento priežastis nežinoma ir ją reprodukuoja target rehearsal;
- nėra įmanomas rollback be duomenų praradimo.

## 14. Rollback planas

Rollback yra saugus tik iki to momento, kol target netapo nauju write source ir nesukūrė naujų neperkeltų duomenų. Todėl jis planuojamas kaip aiškus, riboto laiko sprendimas, ne kaip teorinė galimybė.

1. Sustabdyti Cloudflare cron ir vykstančius writer workflow.
2. Įvertinti, ar target priėmė production write'ų. Jei taip, pirmiausia sprendžiama dėl reverse delta; negalima tyliai nukreipti vartotojų atgal ir prarasti jų pakeitimų.
3. Jei target dar neturi divergent write'ų, grąžinti Worker, Pages ir GitHub secret'us į source Supabase reikšmes.
4. Perdeploy'inti Worker ir Pages, patikrinti login, katalogą ir vieną write scenarijų.
5. Palikti target diagnostikai; nenaikinti volume, logų ir final dump.
6. Užfiksuoti incidentą, priežastį ir naują rehearsal veiksmą prieš kitą bandymą.

## 15. SWOT analizė

| Sritis | Vertinimas |
|---|---|
| **Strengths – stiprybės** | Daugiau kontroliuojamų CPU/RAM/disko resursų; pilna Postgres, pg_cron ir konfigūracijos kontrolė; išlieka patikimas Cloudflare edge/API sluoksnis; Postgres pagrindu migracija palyginti tiesi; galima tiksliai stebėti diską, WAL ir query planus. |
| **Weaknesses – silpnybės** | Vienas VPS yra single point of failure; reikia patiems prižiūrėti patching, TLS/Tunnel, Docker, backup ir incidentus; seni vartotojų JWT nutrūks; self-hosted Stack versijų suderinamumas reikalauja rehearsal; Contabo snapshot nėra HA arba DB backup pakaitalas. |
| **Opportunities – galimybės** | Išspręsti esamą refresh retry ir observability skolą; įvesti external backup/restore drill; aiškiai atskirti read model nuo OLTP; išmatuoti 250k katalogo mastą; sukurti pigią, kontroliuojamą augimo platformą, neperkeliant veikiančio Cloudflare sluoksnio. |
| **Threats – grėsmės** | Pilnas refresh gali suvalgyti I/O/WAL/diską ir naujame VPS; neteisingas Auth URL/JWT/SMTP iškart laužys login; neiškelti private Storage objektai sukels tylius istorinių artefaktų praradimus; dual writer arba per anksti įjungtas cron sukels duomenų skirtumus; nepatikrinti backup'ai neveiks tada, kai jų reikės. |

### Produkto savininko išvada

Contabo pasirinkimas yra racionalus kainos ir kontrolės kompromisas, bet sprendimo vertė bus gaunama tik kartu su operational discipline. Tikslas nėra „turėti Supabase savo serveryje“; tikslas yra patikimas katalogas, admin dashboard ir sinchronizacijos 250k produkto mastu. Cloudflare neperkeliamas, nes jis ir toliau atlieka naudingą edge, cache, webhook ir scheduler vaidmenį. Minimalūs Cloudflare config pakeitimai yra būtina jungtis į naują Supabase, ne architektūros keitimas.

## 16. Orientacinis penkių savaičių planas

| Savaitė | Rezultatas | Vartai |
|---|---|---|
| 1 | source inventory, backup, Contabo hardening, domeno/Tunnel sprendimas | turimas staging VPS ir off-host backup |
| 2 | prisegtas self-hosted stack, pirmas DB + Storage rehearsal | parity ataskaita be nepaaiškintų skirtumų |
| 3 | Auth/SMTP/integracijų testai, pg_cron ir refresh apsaugos | veikia end-to-end staging |
| 4 | 250k performance testas, admin benchmark, backup restore, pilnas cutover rehearsal | visi kritiniai SLO arba formalus blokatorius |
| 5 | produkcinis cutover, 24 h stebėjimas, stabilizavimo ataskaita | Go/no-go ir rollback lango uždarymas |

Laikas yra darbo planas, ne garantija. Jei 3–4 savaitę paaiškėja, kad full refresh strategija netelpa į diską ar SLO, produkcinis perjungimas neturi būti forsuojamas vien dėl kalendoriaus.

## 17. Sprendimai, kuriuos reikia patvirtinti prieš M1

- [ ] Valdomas domenas Cloudflare zonoje ir hostname'ai supabase.<domenas>, supabase-staging.<domenas>, studio.<domenas>.
- [ ] Cloudflare Tunnel priimamas kaip minimalus saugaus publikavimo būdas; jei ne, patvirtinta Caddy/Nginx ir viešo origin rizika.
- [ ] VPS planas Cloud VPS 6 ir ES regionas.
- [ ] Išorinis backup target bei retention.
- [ ] Kas gauna production alertus ir kas turi release/rollback teisę.
- [ ] Ar 5 savaičių planas apima kritinį refresh circuit breaker ir 250k testą prieš cutover.

## 18. Susiję šaltiniai

### Projekto dokumentacija

- [Admin dashboard timeout analizė](admin-dashboard-timeout-analysis.md)
- [Catalog read-model stabilizavimo analizė](catalog-read-model-stabilization.md)
- [Raw sync Storage rollout](raw-sync-storage-rollout.md)
- [Supabase migracija, kuri sukuria pg_cron job'us](../supabase/migrations/20260714205054_stabilize_catalog_refresh.sql)
- [Worker konfigūracija](../apps/api/wrangler.jsonc)
- [GitHub katalogo sinchronizacija](../.github/workflows/sync-catalog.yml)

### Oficiali dokumentacija

- [Supabase Docker self-hosting](https://supabase.com/docs/guides/self-hosting/docker)
- [Supabase Platform projekto atkūrimas į self-hosted](https://supabase.com/docs/guides/self-hosting/restore-from-platform)
- [Supabase self-hosted Postgres 15 → 17 suderinamumo gairės](https://supabase.com/changelog/46080-self-hosted-supabase-upgrading-from-pg-15-to-17-breaking-change)
- [Cloudflare Tunnel apžvalga](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
