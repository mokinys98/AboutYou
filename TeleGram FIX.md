# Telegram alertų ir katalogo publikavimo sinchronizacijos pataisa

## Įgyvendinimo kontrolinis sąrašas

### Atlikta kode

- [x] Pridėtas filtro alerto `last_evaluated_catalog_version` kursorius.
- [x] Filtro alertai vertinami iš publikuoto `catalog_items_read` read modelio.
- [x] Filtro alertų progreso kursorius nebeslenka vien pagal `now()`.
- [x] Outbox įrašams pridėtas `required_catalog_version` saugiklis.
- [x] `claim_telegram_notifications` neima eilės, kurios katalogo versija dar
  nepublikuota.
- [x] Filtro event raktas susietas su katalogo publikacijos versija.
- [x] Telegram filtro nuoroda gauna `catalog_version` parametrą.
- [x] Web aplikacija perduoda `catalog_version` į prekių ir facetų užklausas,
  todėl ankstesnis edge/local cache įrašas nepanaudojamas.
- [x] Nauji ir pakeisti filtro alertai automatiškai pradedami nuo tuo metu
  publikuotos katalogo versijos.

### Dar planuojama prieš production diegimą

- [ ] **Patikrinti migracijos parengtį.** Įsitikinti, kad
  `supabase/migrations/202607210001_telegram_catalog_publication_gate.sql` eina
  po `20260714205054_stabilize_catalog_refresh.sql`. Paleisti `npm test`,
  `npm run typecheck` ir `git diff --check`.
- [ ] **Pasidaryti backup ir pasirinkti langą.** Prieš DB pakeitimą sukurti
  Supabase backup/PITR patikros tašką, užfiksuoti dabartinį
  `completed_version`, `requested_version` ir nebaigtų outbox eilučių skaičių.
  Migraciją vykdyti ne scraperio ir ne refresh darbo metu.
- [ ] **Paleisti migraciją production Supabase projekte.** Supabase SQL Editor
  įvykdyti visą migracijos failo turinį kaip vieną veiksmą arba naudoti
  patvirtintą migracijų pipeline. Nenaudoti atskirų rankinių SQL iškarpų, nes
  funkcijos ir indeksai turi būti įdiegti kartu.
- [ ] **Patikrinti schemą po migracijos.** Service-role SQL užklausa turi parodyti
  naujus laukus ir funkcijas:

  ```sql
  select column_name
  from information_schema.columns
  where table_schema = 'public'
    and table_name in ('alerts', 'telegram_notification_outbox')
    and column_name in ('last_evaluated_catalog_version', 'required_catalog_version')
  order by table_name, column_name;

  select proname
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname in ('evaluate_telegram_alerts', 'claim_telegram_notifications');
  ```

  Antroji užklausa turi grąžinti būtent dvi eilutes:

  ```text
  claim_telegram_notifications
  evaluate_telegram_alerts
  ```

  Tai patvirtina, kad abi funkcijos egzistuoja. Norint patikrinti, kad įdiegta
  būtent nauja jų versija, papildomai vykdyti:

  ```sql
  select p.proname,
         pg_get_function_identity_arguments(p.oid) as arguments
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in ('evaluate_telegram_alerts', 'claim_telegram_notifications')
  order by p.proname, arguments;
  ```

  Turi būti tokios argumentų struktūros (Postgres gali rodyti tik tipus,
  be parametrų pavadinimų):

  ```text
  claim_telegram_notifications | integer, integer
  evaluate_telegram_alerts     | integer
  ```

  Pirmosios užklausos rezultatuose turi būti abu nauji stulpeliai:
  `alerts.last_evaluated_catalog_version` ir
  `telegram_notification_outbox.required_catalog_version`.
- [ ] **Patikrinti alertų backfill.** Įsitikinti, kad visi esami alertai turi
  `last_evaluated_catalog_version >= 0`, o senos pending outbox eilutės turi
  `required_catalog_version` ir filtro payload turi `catalogVersion`.
- [x] **Patikrinti `pg_cron` refresh.** Supabase Cron/SQL Editor patikrinti, kad
  `catalog-read-model-refresh` egzistuoja ir po sync:

  ```sql
  select requested_version, completed_version, last_status,
         refresh_started_at, refresh_completed_at, last_error
  from public.catalog_read_model_refresh_state
  where singleton;
  ```

  Sėkmingai užbaigus refresh turi būti `completed_version >= requested_version`
  ir `last_status` turi būti `refreshed` arba `clean`. Production patikroje
  gauta `requested_version = 107`, `completed_version = 107`, `last_status = clean`,
  `last_error = null`; paskutinis refresh truko apie 25,5 s.
- [x] **Atlikti kontroliuojamą sync testą.** Paleisti vieną realų arba riboto
  dydžio catalog sync ir užfiksuoti versiją prieš bei po jo. Sync viduryje
  Telegram alertų vertinimas neturi sukurti naujo filtro outbox pranešimo.
  Atliktame teste sync baigėsi `success` su 314 prekėmis, outbox liko 17 eilučių,
  o filtro alertų kursoriai vėliau pasiekė 116.
- [x] **Patikrinti publikavimą ir siuntimą.** Po refresh įsitikinti, kad filtro
  outbox payload turi tą pačią `catalogVersion` kaip
  `required_catalog_version`, o claim funkcija eilę paima tik tada, kai ši
  versija ne didesnė už `completed_version`. Production patikroje visos
  pateiktos eilutės turėjo `required_catalog_version = 107`,
  `payload.catalogVersion = 107` ir būseną `sent`.
- [x] **Atlikti paspaudimo testą.** Gauti testiniai Telegram pranešimai buvo
  atidaryti iškart po siuntimo. Abiejose nuorodose (`category` ir
  `price_max/discount_min`) yra `catalog_version=117`; DB tuo metu taip pat
  rodė `completed_version = 117`, o išsiųstų outbox eilučių
  `required_catalog_version = payload.catalogVersion = 117`. Tai patvirtina,
  kad nuoroda generuojama tik publikuotai katalogo versijai.
- [ ] **Išbandyti seną cache.** Prieš refresh užkrauti tą patį filtrą, kad būtų
  sukurtas tuščias atsakymas. Po refresh paspausti versijuotą Telegram nuorodą;
  prekė turi būti matoma nepaisant ankstesnio cache įrašo.
- [ ] **Išbandyti klaidos ir retry scenarijus.** Sukelti arba stebėti refresh
  timeout bei Telegram 429/5xx. Refresh klaidos metu alerto versijos kursorius
  neturi pasistūmėti, o Telegram klaida turi grįžti į tą pačią outbox eilę.
- [ ] **Apsispręsti dėl partial sync.** Aiškiai pasirinkti, ar dalinai
  nesėkmingo sync rezultatas gali būti publikuojamas. Jei ne, prieš production
  įdiegti papildomą sąlygą, kuri neleidžia alertų vertinti po `partial` ciklo.
- [ ] **Stebėti pirmus ciklus.** Bent kelis refresh/sync ciklus stebėti
  `catalog_read_model_refresh_state`, `telegram_notification_outbox` ir
  Telegram klaidų logus. Tik tada pažymėti šiuos punktus kaip atliktus.

### VPS: `pg_cron` patikra ir rankinis paleidimas

`pg_cron` yra PostgreSQL plėtinys. Self-hosted Supabase atveju jo nereikia
paleisti per Linux `crontab`; jis veikia DB konteineryje kaip PostgreSQL
background worker.

#### 1. Prisijungti prie VPS ir rasti DB konteinerį

```bash
ssh root@<VPS_HOST>
cd /opt/supabase/docker
docker compose ps
```

Jei gaunama klaida `no configuration file provided: not found`, komanda
paleista ne tame kataloge, kuriame yra `compose.yml`. Tada rasti Compose
projekto katalogą ir konteinerį:

```bash
docker compose ls
docker ps --format 'table {{.Names}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Label "com.docker.compose.service"}}'
```

Arba gauti tikslų veikiančio `db` serviso kelią:

```bash
DB_CONTAINER=$(docker ps -q --filter label=com.docker.compose.service=db | head -n 1)
docker inspect "$DB_CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'
docker inspect "$DB_CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}'
```

Į gautą `working_dir` katalogą reikia pereiti su `cd`, tada kartoti
`docker compose exec` komandą. Jei Compose katalogo rasti nepavyksta, galima
naudoti tiesioginį Docker variantą:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}'
docker exec -it <DB_CONTAINER_NAME> psql -U postgres -d postgres -c \
"select public.process_catalog_items_read_refresh();"
```

Ši klaida pati savaime nereiškia nei PostgreSQL, nei `pg_cron` gedimo — tai tik
reiškia, kad `docker compose` nerado konfigūracijos failo dabartiniame kataloge.

Oficialiame Supabase Docker Compose projekte DB servisas dažniausiai vadinasi
`db`. Jei pavadinimas kitoks, jį reikia pakeisti tolesnėse komandose.

#### 2. Patikrinti, ar įjungtas `pg_cron`

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
"select extname, extversion from pg_extension where extname = 'pg_cron';"
```

Jei grįžta `pg_cron` eilutė, plėtinys įdiegtas. Jei gaunama klaida
`extension "pg_cron" is not available`, pirmiausia reikia naudoti Supabase
Postgres image, kuriame yra šis plėtinys, ir įjungti `pg_cron` per PostgreSQL
konfigūraciją. Nereikia aklai diegti OS paketo į host sistemą, jei PostgreSQL
veikia Docker konteineryje.

Papildomai patikrinti scheduler nustatymus:

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
"select name, setting from pg_settings where name like 'cron.%' order by name;"
```

#### 3. Patikrinti, ar egzistuoja katalogo refresh job

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
"select jobid, jobname, schedule, command, active
 from cron.job
 where jobname = 'catalog-read-model-refresh';"
```

Tikėtina reikšmė:

```text
jobname: catalog-read-model-refresh
schedule: */5 * * * *
command: select public.process_catalog_items_read_refresh();
active: true
```

#### 4. Paleisti refresh funkciją iškart, nelaukiant cron intervalo

Tai paleidžia pačią funkciją tiesiogiai ir nekuria antro cron job:

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
"select public.process_catalog_items_read_refresh();"
```

Normalus atsakymas bus JSON su `status`: `refreshed`, `clean` arba `busy`.
`busy` reiškia, kad kitas refresh jau laiko advisory lock; tokiu atveju palaukti
ir nekviesti funkcijos lygiagrečiai.

Svarbu: ši komanda tik atnaujina katalogo read modelį. Ji nesiunčia Telegram
žinučių. Telegram alertų įvertinimą galima patikrinti atskirai:

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
"select public.evaluate_telegram_alerts(500);"
```

Ši funkcija tik įrašo pranešimus į outbox; jų išsiuntimą atlieka API Worker.

#### 5. Patikrinti cron vykdymo istoriją ir klaidas

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
"select job.jobname, runs.status, runs.return_message,
        runs.start_time, runs.end_time
 from cron.job_run_details runs
 join cron.job job on job.jobid = runs.jobid
 where job.jobname = 'catalog-read-model-refresh'
 order by runs.start_time desc
 limit 20;"
```

`status = succeeded` reiškia sėkmingą cron paleidimą. Klaidos priežastis bus
`return_message` lauke; papildomą PostgreSQL konteinerio logą galima peržiūrėti:

```bash
docker compose logs --tail=200 db
```

#### 6. Patikrinti publikacijos versiją po paleidimo

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
"select requested_version, completed_version, last_status,
        refresh_started_at, refresh_completed_at, last_error
 from public.catalog_read_model_refresh_state
 where singleton;"
```

Sėkmės kriterijus: `completed_version >= requested_version`,
`last_status in ('clean', 'refreshed')` ir `last_error is null`.

#### 7. Keisti grafiką tik jei to tikrai reikia

Pirmiausia gauti `jobid` iš `cron.job`, tada naudoti `cron.alter_job`; nekeisti
`cron.job` lentelės tiesiogiai:

```sql
select cron.alter_job(
  <JOB_ID>,
  schedule := '*/5 * * * *',
  active := true
);
```

Jei job visiškai nėra, jį sukurti tik vieną kartą:

```sql
select cron.schedule(
  'catalog-read-model-refresh',
  '*/5 * * * *',
  'select public.process_catalog_items_read_refresh();'
);
```

Nekviesti `cron.schedule` pakartotinai, jei job jau egzistuoja, nes galima
netyčia perrašyti jo grafiką ar sukurti neplanuotą konfigūracijos pokytį.

### Praktinės priėmimo testų procedūros

Šiuos testus geriausia vykdyti staging aplinkoje arba su atskiru testiniu
Telegram alertu. Prieš kiekvieną testą užsirašyti dabartinę katalogo versiją:

```bash
docker exec -i supabase-db psql -U postgres -d postgres -c \
"select requested_version, completed_version
 from public.catalog_read_model_refresh_state where singleton;"
```

#### Testas A: sync viduryje

Šiam testui yra du variantai:

- **Saugos smoke testas (rekomenduojamas pirmas).** Naudoti jau egzistuojantį
  aktyvų filtro alertą ir patikrinti, kad katalogo rašymo metu jo versijos
  kursorius bei outbox nepasistūmėja. Šiam variantui nereikia garantuoti naujos
  prekės — tikrinama, kad viduryje sync nepradedamas siuntimas.
- **Pilnas end-to-end testas.** Laikinai sukurti filtro alertą per web UI,
  prijungti testinį Telegram chatą ir pasirinkti filtrą, kuriam sync tikrai
  atneš naują prekę. Jei nėra žinomos naujos prekės arba testinio fixture,
  šio varianto production aplinkoje vykdyti nereikia.

Prieš sync užsirašyti pasirinkto alerto ID, jo
`last_evaluated_catalog_version` ir outbox eilučių skaičių:

```bash
docker exec -i supabase-db psql -U postgres -d postgres -c \
"select id, kind, enabled, last_evaluated_catalog_version
 from public.alerts
 where kind = 'filter' and enabled
 order by updated_at desc limit 10;"

docker exec -i supabase-db psql -U postgres -d postgres -c \
"select count(*) as outbox_count
 from public.telegram_notification_outbox;"
```

Tada paleisti įprastą `Sync catalog` GitHub Actions workflow (`Actions` → `Sync
catalog` → `Run workflow`). Jei sync paleidžiamas kitu būdu, svarbu užfiksuoti
jo pradžios laiką.

Kol sync vyksta, patikrinti:

   ```bash
   docker exec -i supabase-db psql -U postgres -d postgres -c \
   "select id, status, started_at, finished_at, products_count
    from public.sync_runs
    where status = 'running'
    order by started_at desc;"
   ```

Kol yra `status = running`, paleisti:

   ```bash
   docker exec -i supabase-db psql -U postgres -d postgres -c \
   "select public.evaluate_telegram_alerts(500);"
   ```

Patikrinti, kad neatsirado nauja filtro outbox eilutė su nauja versija, kol
   `completed_version` dar nepasikeitė.
Sync pabaigoje palaukti, kol `requested_version = completed_version`, tada
   dar kartą paleisti alertų vertinimą. Tik dabar leidžiamas naujas filtro
   outbox įrašas.

Pass kriterijus smoke testui: kol sync vyksta, filtro alerto
`last_evaluated_catalog_version` ir outbox skaičius nepasikeičia dėl naujos
nepublikuotos prekės. Pilnam end-to-end testui papildomai turi atsirasti viena
outbox eilė tik po sėkmingo refresh, o jos `catalogVersion` turi sutapti su
`completed_version`.

#### Testas B: Telegram nuoroda iškart po siuntimo

1. Po sėkmingo refresh paleisti testinį alertų vertinimą arba palaukti Workerio
   ciklo.
2. Iš Telegram žinutės iškart paspausti `Atidaryti kataloge`.
3. Patikrinti, kad nuorodoje yra `catalog_version=<V>`.
4. Tą pačią versiją ir žinutės prekę patikrinti DB:

   ```bash
   docker exec -i supabase-db psql -U postgres -d postgres -c \
   "select status, required_catalog_version,
           payload->>'catalogVersion' as payload_version,
           payload->'products' as products
    from public.telegram_notification_outbox
    where status = 'sent'
    order by sent_at desc limit 1;"
   ```

Pass kriterijus: prekė matoma pirmame katalogo rezultate, o payload versija,
URL versija ir `completed_version` sutampa.

Production patikroje gautos dvi Telegram nuorodos su `catalog_version=117`;
`catalog_read_model_refresh_state` ir naujausios išsiųstos outbox eilutės taip
pat buvo 117 versijos.

#### Testas C: seno cache scenarijus

1. Prieš naują refresh naršyklėje atidaryti tą patį filtrą, kad būtų išsaugotas
   senas arba tuščias `/v1/catalog` atsakymas.
2. Užbaigti sync ir refresh.
3. Gauti naują Telegram pranešimą ir atidaryti jo versijuotą nuorodą.
4. Patikrinti, kad URL turi naują `catalog_version`, todėl naudojamas naujas
   edge cache raktas; facetų localStorage raktas taip pat turi skirtis.

Pass kriterijus: senas tuščias atsakymas negrįžta ir nauja prekė rodoma.

#### Testas D: refresh klaida ir Telegram retry

Refresh klaidos scenarijų dirbtinai sukelti tik staging aplinkoje. Production
pakanka tikrinti natūralios klaidos ir retry įrašus.

Refresh būseną tikrinti taip:

```bash
docker exec -i supabase-db psql -U postgres -d postgres -c \
"select requested_version, completed_version, last_status, last_error
 from public.catalog_read_model_refresh_state where singleton;"
```

Pass kriterijus refresh klaidos metu: `last_status = failed`,
`completed_version` nepasistūmėja, filtro alerto versijos kursorius nepajuda ir
naujas pranešimas neišsiunčiamas.

Telegram retry būseną tikrinti taip:

```bash
docker exec -i supabase-db psql -U postgres -d postgres -c \
"select id, status, attempts, next_attempt_at, last_error
 from public.telegram_notification_outbox
 where status in ('pending', 'processing', 'dead')
 order by updated_at desc limit 20;"
```

Transient 429/5xx atveju eilė turi likti `pending` su padidėjusiu `attempts` ir
`next_attempt_at` ateityje. `dead` reiškia, kad pasiektas retry limitas arba
klaida pažymėta permanentine; tokią eilę reikia tirti, o ne kartotinai kurti
naują alertą.

### Vėlesni patobulinimai

- [ ] Pridėti atskirą katalogo generation/publication modelį, jei reikės rollback,
  kelių aktyvių kartų ar atominiu būdu perjungiamų read-model lentelių.

## Problemos santrauka

Dabartinis filtro alertas gali būti išsiųstas anksčiau, negu tą pačią prekę gali
parodyti Telegram nuorodos atidaromas katalogas.

Tai nėra Telegram API problema. Telegram tik išsiunčia jau paruoštą outbox
pranešimą. Problema yra ta, kad alertų vertinimas ir vartotojui skirto katalogo
publikavimas yra du nepriklausomi procesai, naudojantys skirtingus duomenų
vaizdus.

## Kaip dabar vyksta procesas

1. `apps/sync/src/index.ts` sinchronizacijos metu kas 200 prekių kviečia
   `record_catalog_batch` ir iškart keičia bazines `products`, `offers` bei
   kategorijų lenteles.
2. Telegram Worker kas 5 minutes kviečia `processTelegramAlerts`.
3. `evaluate_telegram_alerts` filtro alertus tikrina per gyvą
   `public.catalog_items` view. Todėl jis naują prekę pamato vos ją įrašius, net
   jeigu likusi katalogo sinchronizacija dar vyksta.
4. Filtro pranešimas iškart įrašomas į `telegram_notification_outbox`, tame
   pačiame Worker cikle rezervuojamas ir išsiunčiamas.
5. Tuo metu svetainės `/v1/catalog` skaito ne `catalog_items`, o materialized
   view `catalog_items_read`.
6. Catalog sync tik pačioje pabaigoje kviečia
   `request_catalog_items_read_refresh`. Tikrą refresh atskiras `pg_cron`
   paleidžia kas 5 minutes.

Esama lenktynių sąlyga:

```text
sync įrašo prekę į bazines lenteles
        │
        ├── Telegram alertas skaito catalog_items ──> išsiunčia pranešimą
        │
        └── catalog_items_read dar senas ───────────> nuorodoje prekės nėra
                                                      │
                                      vėliau įvyksta refresh
```

Papildomai `/v1/catalog` rezultatą Worker Cache API saugo 300 sekundžių. Jei to
filtro tuščias arba senas atsakymas jau buvo užcache'intas, vien sėkmingo
materialized view refresh neužtenka: vartotojas dar iki 5 minučių gali gauti
seną rezultatą. Facetai taip pat cache'inami, o naršyklėje jų cache galioja iki
24 valandų.

## Būtina garantija

Filtro Telegram pranešimas gali būti pristatytas tik tada, kai tenkinamos abi
sąlygos:

1. alertas įvertintas pagal jau publikuotą `catalog_items_read` versiją;
2. Telegram nuorodos pirmas katalogo užkrovimas negali gauti ankstesnės
   katalogo versijos cache įrašo.

Vien `sleep`, fiksuotas 5 minučių laukimas arba cron eiliškumo pakeitimas tokios
garantijos nesuteikia. Refresh gali trukti ilgiau, nepavykti arba persidengti su
kitu ciklu.

## Variantai

### 1. Rekomenduojamas: versijuotas read modelio publikavimas

Tai mažiausias sprendimas, kuris duoda aiškią ir testuojamą garantiją.

#### Duomenų bazė

- Į `alerts` pridėti filtro alerto kursorių, pvz.
  `last_evaluated_catalog_version bigint`.
- Naujam alertui įrašyti tuo metu esančią
  `catalog_read_model_refresh_state.completed_version`. Taip vartotojas negaus
  pranešimų apie iki alerto sukūrimo jau publikuotas prekes.
- `evaluate_telegram_alerts` filtro šaką vykdyti tik kai
  `completed_version > last_evaluated_catalog_version`.
- Filtro atitikmenis skaityti iš `catalog_items_read`, t. y. iš to paties
  read modelio, kurį skaito `/v1/catalog`, o ne iš gyvo `catalog_items` view.
- Į outbox payload įrašyti `catalogVersion = completed_version`.
- Tik sėkmingai sukūrus outbox įrašą arba patikimai užbaigus konkrečios
  publikacijos vertinimą perkelti alerto kursorių į tą versiją.
- Jei refresh nepavyko arba nauja versija dar tik `requested`, alerto kursoriaus
  nejudinti ir filtro pranešimo nesiųsti.

Svarbu: nereikia vien pakeisti `catalog_items` į `catalog_items_read` ir palikti
`last_evaluated_at = now()`. Telegram cron gali perskaityti seną materialized
view ir pastumti laiko kursorių už dar nepublikuotos prekės `first_seen_at`;
tuomet alertas būtų prarastas. Versijos kursorius pašalina šią spragą.

`last_evaluated_at` galima palikti diagnostikai, bet filtro alerto duomenų
progreso šaltinis turi būti katalogo versija, ne Worker sieninis laikas.

#### API ir cache

- `notificationUrl` filtro nuorodoje pridėti, pvz.,
  `catalog_version=<completed_version>`.
- `apps/web/pages/index.vue` įtraukti `catalog_version` į perduodamus query
  parametrus, kad jis pasiektų `/v1/catalog` ir `/v1/catalog/facets`.
- API gali šį parametrą ignoruoti filtravimo prasme. Jis vis tiek taps Worker
  cache rakto dalimi ir neleis panaudoti ankstesnės katalogo versijos atsakymo.
- Dar griežtesnis pasirinkimas: užklausoms su `catalog_version` visai apeiti
  katalogo ir facetų edge cache. Tai padidina vieno Telegram paspaudimo DB
  kainą, bet yra paprasčiausia matomumo garantija.
- Naršyklės 24 val. facetų cache rakte taip pat turi dalyvauti katalogo versija
  arba Telegram atidarymui facetai turi būti priverstinai atnaujinti. Prekių
  sąrašui tai nėra pagrindinė kliūtis, bet kitaip filtrų skaičiai gali likti
  seni.

#### Seka po pataisos

```text
sync baigia rašymą
   │
   └── request refresh V
            │
            └── refresh sėkmingas, completed_version = V
                         │
                         └── alertas skaito catalog_items_read@V
                                      │
                                      └── outbox payload: catalogVersion=V
                                                   │
                                                   └── Telegram nuoroda su V
                                                       negauna seno cache
```

#### Privalumai

- Alertas ir UI remiasi tuo pačiu publikuotu duomenų rinkiniu.
- Nėra laukimo pagal spėjamą laiką.
- Refresh klaidos atveju klaidingas pranešimas neišsiunčiamas.
- Išlieka dabartinis patikimas outbox, lease ir retry mechanizmas.
- Nereikia laikyti DB transakcijos atviros siunčiant HTTP užklausą į Telegram.

#### Trūkumai

- Reikia DB migracijos ir pakeitimų API bei web aplikacijoje.
- Reikia apibrėžti seno alerto kursoriaus backfill. Saugus variantas: esamiems
  alertams nustatyti dabartinę `completed_version`, kad diegimo metu nebūtų
  masinio istorinių pranešimų siuntimo.

### 2. Post-sync orkestravimas GitHub Actions pusėje

Catalog sync pabaigoje:

1. gauti `request_catalog_items_read_refresh()` grąžintą versiją `V`;
2. periodiškai tikrinti, kol `completed_version >= V`;
3. tik tada per apsaugotą API endpointą paleisti alertų vertinimą;
4. į Telegram nuorodą vis tiek įdėti `V` arba apeiti cache.

Reguliarus 5 minučių Worker cron šiuo atveju turėtų tik pristatyti jau paruoštą
outbox arba filtro alertų visai nevertinti. Kitaip senoji lenktynių sąlyga liks.

#### Privalumai

- Procesas labai aiškus operaciniu požiūriu: sync → refresh → alerts.
- Mažiau periodinio tuščio alertų tikrinimo.

#### Trūkumai

- GitHub job turi laukti DB darbo ir gali viršyti timeout.
- Reikia naujo autentifikuoto vidinio endpointo arba kito saugaus trigerio.
- Jei workflow nutrūksta jau po sėkmingo refresh, alertus turi perimti retry ar
  atskiras recovery job.
- Cache versijavimo problemos šis variantas vienas neišsprendžia.

Šį variantą verta rinktis tik jei norima, kad visas katalogo publikavimo
pipeline būtų valdomas iš GitHub Actions.

### 3. Outbox pristatymo vartai pagal privalomą katalogo versiją

Outbox įrašui pridėti `required_catalog_version`. Funkcija
`claim_telegram_notifications` galėtų rezervuoti tik tuos pranešimus, kurių
versija jau publikuota:

```sql
required_catalog_version <= completed_version
```

Tai geras papildomas „paskutinės gynybos“ sluoksnis, tačiau vienas pats dabartinės
problemos neišsprendžia. Sync pradžioje dar nėra rezervuotos būsimos versijos,
todėl viduryje sync sukurtas alertas galėtų gauti seną jau užbaigtą versiją ir
būti išsiųstas iškart.

Kad šis variantas veiktų savarankiškai, reikėtų:

- prieš pirmą katalogo įrašą rezervuoti publikacijos versiją;
- visus sync pakeitimus susieti su ta versija;
- neleisti refresh pažymėti versijos užbaigta, kol visas sync ciklas nebaigtas;
- outbox payload ir cache raktą susieti su ta pačia versija.

Tai iš esmės tampa pilnu 4 varianto publikavimo modeliu.

### 4. Ilgalaikis: pilnas katalogo generation/publication modelis

Kiekvienam viso katalogo sync ciklui sukurti `catalog_generation`:

- `collecting` – scraper dar rašo duomenis;
- `ready` – visi pasirinkti targetai užbaigti ir karta paruošta publikavimui;
- `publishing` – kuriamas read modelis;
- `published` – UI ir alertai gali naudoti šią kartą;
- `failed` – karta nepublikuojama arba publikuojama pagal aiškią partial politiką.

Produktų pasikeitimai, read modelis, alertų kursoriai ir outbox būtų susieti su
generation ID. Telegram siunčia tik `published` kartos įvykius.

#### Privalumai

- Stipriausia semantika ir geriausias auditas.
- Aiškiai sprendžia dalinio sync, kelių targetų, retry ir persidengiančių darbų
  atvejus.
- Ateityje leidžia saugiai pereiti nuo materialized view prie atominiu būdu
  perjungiamų read-model lentelių.

#### Trūkumai

- Daugiausia schemos ir sync pipeline pakeitimų.
- Reikia nuspręsti duomenų saugojimo bei senų generation valymo politiką.

Tai geriausia kryptis ilgalaikiam katalogo patikimumui, bet dabartinei klaidai
gali būti per didelė apimtis.

## Rekomendacija

Įgyvendinti **1 variantą**, papildant jį nedideliu 3 varianto saugikliu:

1. filtro alertų šaltinis – tik `catalog_items_read`;
2. filtro alertų kursorius – `completed_version`, ne `now()`;
3. outbox payload ir, pageidautina, pati outbox eilutė saugo
   `required_catalog_version`;
4. claim papildomai patikrina, kad reikalinga versija dar tebėra publikuota;
5. Telegram filtro URL perduoda `catalog_version`;
6. Telegram atidarymo užklausa apeina seną edge cache arba naudoja versijuotą
   cache raktą;
7. refresh klaidos atveju alertas lieka neįvertintas ir bus paimtas po kito
   sėkmingo refresh.

Tokiu būdu notification faktas reikš ne „prekė jau įrašyta į bazines lenteles“,
o „prekė jau yra konkrečioje vartotojui matomo katalogo versijoje“.

## Ko nedaryti

- Nedėti aklo `sleep(5 min)` prieš Telegram siuntimą.
- Nepasitikėti tuo, kad abu cron paleidžiami kas 5 minutes – jų tarpusavio tvarka
  negarantuojama.
- Neužtenka tik patikrinti `last_status = 'clean'`: sync viduryje būsena dar gali
  būti „clean“ nuo ankstesnės versijos, nes refresh prašymas dabar sukuriamas tik
  sync pabaigoje.
- Nelaikyti DB transakcijos ar advisory lock, kol vyksta išorinis Telegram HTTP
  call. Outbox jau teisingai atskiria trumpą DB rezervavimą nuo tinklo siuntimo.
- Nekeisti tik alerto SQL į `catalog_items_read`, paliekant sieninio laiko
  kursorių – taip galima tyliai praleisti alertus.

## Priėmimo testai

1. **Telegram tick sync viduryje.** Paleisti lėtą sync, kad Worker cron įvyktų po
   pirmo batch. Iki sėkmingo read-model refresh filtro pranešimas neturi būti
   išsiųstas.
2. **Momentinis paspaudimas.** Gavus pranešimą iškart atidaryti nuorodą. Bent
   viena payload nurodyta prekė turi būti pirmo `/v1/catalog` atsakymo
   rezultatuose.
3. **Senas cache.** Prieš refresh atidaryti tą patį filtrą ir užcache'inti tuščią
   rezultatą. Po refresh gauta Telegram nuoroda vis tiek turi parodyti prekę.
4. **Refresh klaida.** Dirbtinai sukelti refresh timeout. Alertas neturi būti
   išsiųstas ir jo katalogo versijos kursorius neturi pasistūmėti.
5. **Pakartotinis cron.** Du Worker paleidimai neturi sukurti dviejų vienodos
   publikacijos pranešimų. Turi veikti esami advisory lock, unikalus `event_key`
   ir outbox lease.
6. **Naujas refresh vertinimo metu.** Jei vertinant versiją `V` jau paprašyta
   `V+1`, alertas turi užbaigti tik `V`; kitame cikle atskirai įvertinti `V+1`.
7. **Dalinai nepavykęs sync.** Pagal pasirinktą politiką partial karta arba
   nepublikuojama, arba alertai siunčiami tik po to, kai tas partial rezultatas
   tikrai matomas read modelyje. Jokiu atveju nesiųsti prieš publikavimą.
8. **Telegram retry.** Telegram 429/5xx neturi pakartotinai vertinti katalogo ar
   kurti kito event; turi būti kartojamas tos pačios outbox eilutės pristatymas.

## Susijusios kodo vietos

- `.github/workflows/sync-catalog.yml` – katalogo workflow ir jo concurrency.
- `apps/sync/src/index.ts` – batch įrašymas ir refresh užklausa tik sync
  pabaigoje.
- `apps/api/src/index.ts` – atskiras 5 min Telegram cron, `/v1/catalog` skaitymas
  iš `catalog_items_read` ir 300 s edge cache.
- `apps/api/src/telegram.ts` – alertų evaluate → claim → send → complete seka ir
  Telegram filtro URL sudarymas.
- `apps/web/pages/index.vue` – leistinų URL filtrų sąrašas, API query sudarymas ir
  24 val. facetų localStorage cache.
- `supabase/migrations/202607140001_telegram_alerts.sql` – dabartinis filtro
  vertinimas iš `catalog_items`, outbox bei lease/retry funkcijos.
- `supabase/migrations/20260714205054_stabilize_catalog_refresh.sql` –
  `requested_version` / `completed_version`, refresh worker ir 5 min `pg_cron`.
