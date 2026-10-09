# PostgreSQL Exporter įdiegimas VPS stebėsenai

Ši instrukcija prijungia `prometheus-community/postgres_exporter` prie jau veikiančio Supabase PostgreSQL ir Prometheus. Eksportuotojas veikia tik Docker tinkluose, neturi viešai paskelbto prievado ir naudoja atskirą paskyrą su `pg_monitor` role.

## Ką rinksime

- PostgreSQL ir exporter’io pasiekiamumą.
- Aktyvias, laukiančias ir neaktyvias jungtis bei maksimalų jungčių skaičių.
- Transakcijas, commit, rollback, konfliktus ir deadlock’us.
- `pg_stat_statements` suvestines pagal normalizuotą užklausos ID, be SQL teksto.
- Cache hit santykį, blokų skaitymą, laikinus failus, užraktus ir ilgas transakcijas.
- Duomenų bazių, lentelių ir indeksų dydžio bei naudojimo statistiką.
- Vacuum/analyze, WAL, checkpoint ir duomenų bazės wraparound statistiką.
- VPS CPU, RAM ir failų sistemos naudojimą iš jau veikiančio Node Exporter.

Lėtų užklausų skydelis rodys statistines suvestines. Jis nerinks užklausų tekstų, parametrų ar vykdymo planų.

## Prieš pradedant

VPS Prometheus, Grafana ir Node Exporter jau turi veikti. Supabase duomenų bazės Docker konteineris šiame projekte vadinamas `supabase-db`, o Supabase ir stebėsenos Compose projektai veikia atskirai.

2026-10-07 read-only patikra parodė PostgreSQL 17.6 ir įdiegtą `pg_stat_statements` plėtinį `postgres` duomenų bazėje.

2026-10-07 vartotojo pateikta Supabase SQL Editor ekrano kopija patvirtino, kad stebėsenos rolės migracija įvykdyta, o atskira patikra grąžino `can_login = true`, `can_connect = true` ir `granted_monitor_role = pg_monitor`.

2026-10-07 vartotojo pateikta VPS `docker network ls` ir `docker inspect supabase-db` išvestis patvirtino, kad duomenų bazės tinklas vadinasi `supabase_default`.

2026-10-07 exporter konteinerio logai patvirtino prisijungimą prie PostgreSQL 17.6, bet `stat_statements` kolektorius nerado `pg_stat_statements(boolean)`. SQL Editor patikra parodė, kad plėtinys yra `extensions` schemoje, o `supabase_metrics` neturi šios schemos `USAGE` teisės ar atskiro paieškos kelio. Papildoma migracija įvykdyta; read-only patikra per autorizuotą DB tunelį patvirtino `USAGE = true` ir DB `postgres` nustatymą `search_path="extensions, pg_catalog"`.

2026-10-07 po exporter konteinerio perkrovimo klaida pasikartojo. SQL Editor neleido `SET ROLE supabase_metrics`, todėl paruoštas monitoring Compose pakeitimas, kuris tiesiogiai nustato `search_path=extensions,pg_catalog` kiekvienam exporter'io PostgreSQL prisijungimui per libpq `options` parametrą.

2026-10-07 vartotojas įkėlė atnaujintą Compose konfigūraciją į VPS; `docker compose config -q` praėjo, o `postgres-exporter` konteineris buvo sėkmingai perkurtas. Patikra atlikta iškart po paleidimo, todėl naujo scrape logai dar nepateikti.

2026-10-07 vartotojo pateiktas Grafana Explore rezultatas patvirtino `up{job="postgres"} = 1` ir `pg_up = 1`: Prometheus scrape veikia, o exporter prisijungia prie duomenų bazės. `pg_stat_statements` metrikų buvimas ir klaidų nebuvimas loguose dar tikrinami.

2026-10-07 vartotojo pateiktuose naujausiuose loguose nėra `stat_statements` klaidų, o Grafana Explore grąžino daug `pg_stat_statements_calls_total` serijų su `queryid`, `user` ir `datname` žymomis. Tai patvirtina `pg_stat_statements` rinkimą be užklausų teksto žymos. Liko importuoti Grafana dashboard'ą.

## Diegimo žingsniai

### 1. Nustatyk Supabase Docker tinklo vardą

Atidaryk PuTTY sesiją į VPS ir vykdyk tik šias apžiūros komandas:

```bash
docker network ls
docker inspect supabase-db --format '{{json .NetworkSettings.Networks}}'
```

Užsirašyk tinklo vardą, kuriame yra `supabase-db`. Šios komandos nieko nekeičia. Patikrinus šį VPS, tinklo vardas yra `supabase_default`.

### 2. Sukurk stebėsenos rolę per Supabase SQL Editor

Atidaryk [migracijos SQL failą](../supabase/migrations/20261007153531_add_postgres_exporter_monitoring_role.sql), įkelk visą jo turinį į Supabase SQL Editor ir paleisk. Migracija sukuria `supabase_metrics` login rolę, jai suteikia `CONNECT` prie `postgres` DB ir `pg_monitor` statistiką skaitančias teises. Programos lentelių skaitymo teisės nesuteikiamos.

Tada SQL Editor atskirai paleisk šį sakinį. Prieš paleisdamas pakeisk vietaženklius ilgu, atsitiktiniu slaptažodžiu, kurį pats sugeneravai. Naudok tik raides ir skaičius, kad nereikėtų SQL kabučių escapinti:

```sql
ALTER ROLE supabase_metrics WITH PASSWORD '<TAVO_SUGENERUOTAS_SLAPTAŽODIS>';
```

Nedėk slaptažodžio į šį dokumentą, migracijos failą, Git ar pokalbį.

### 3. Patikrink rolę read-only užklausa

SQL Editor paleisk:

```sql
SELECT
  role.rolname,
  role.rolcanlogin AS can_login,
  has_database_privilege(role.oid, 'postgres', 'CONNECT') AS can_connect,
  monitor_role.rolname AS granted_monitor_role
FROM pg_catalog.pg_roles AS role
LEFT JOIN pg_catalog.pg_auth_members AS membership
  ON membership.member = role.oid
LEFT JOIN pg_catalog.pg_roles AS monitor_role
  ON monitor_role.oid = membership.roleid
  AND monitor_role.rolname = 'pg_monitor'
WHERE role.rolname = 'supabase_metrics';
```

Tikėtinas rezultatas: viena eilutė su `can_login = true`, `can_connect = true`, `granted_monitor_role = pg_monitor`. Jei rezultatas kitoks arba migracija grąžina klaidą, sustok ir išsaugok klaidos tekstą. Nekartok migracijos aklai — pirmiau patikrink, kurie SQL sakiniai jau pritaikyti.

### 4. Suteik exporter'iui prieigą prie `pg_stat_statements` schemos

Įkelk visą [papildomos migracijos SQL failą](../supabase/migrations/20261007160116_configure_postgres_exporter_extension_access.sql) į Supabase SQL Editor ir paleisk. Ji suteikia `USAGE` teisę tik `extensions` schemai ir nustato `search_path` tik `supabase_metrics` prisijungimams prie `postgres` DB.

Exporter'io Compose URI taip pat tiesiogiai nustato `search_path` prisijungimo metu. Tai užtikrina, kad `pg_stat_statements` funkcija būtų pasiekiama net jei SQL Editor rolės imitavimo patikra negalima.

Po to paleisk šią read-only patikrą:

```sql
SELECT
  role.rolname,
  has_schema_privilege(role.oid, 'extensions', 'USAGE') AS can_use_extensions,
  database.datname,
  setting.setconfig
FROM pg_catalog.pg_roles AS role
JOIN pg_catalog.pg_database AS database
  ON database.datname = 'postgres'
LEFT JOIN pg_catalog.pg_db_role_setting AS setting
  ON setting.setrole = role.oid
  AND setting.setdatabase = database.oid
WHERE role.rolname = 'supabase_metrics';
```

Tikėtinas rezultatas: `can_use_extensions = true`, o `setconfig` turi `search_path=extensions, pg_catalog`. Jei rezultatas kitoks, nestartuok exporter'io ir pirmiau patikrink SQL Editor klaidą.

### 5. Perkelk stebėsenos konfigūraciją į VPS

Iš projekto WinSCP nukopijuok šiuos atnaujintus failus į `/srv/monitoring`, išsaugodamas jų vardus:

- `ops/monitoring/compose.yaml`
- `ops/monitoring/prometheus.yml`

Prieš kopijuodamas padaryk šių dviejų VPS failų kopijas. Esamo `/srv/monitoring/.env` neperrašyk.

### 6. Įrašyk tinklą ir slaptažodį į VPS `.env`

VPS `/srv/monitoring/.env` faile pridėk arba atnaujink šias eilutes. Į `SUPABASE_DOCKER_NETWORK` įrašyk 1 žingsnyje patikrintą tinklo vardą, o `POSTGRES_EXPORTER_PASSWORD` — tą patį slaptažodį, kurį nustatei SQL Editor:

```dotenv
SUPABASE_DOCKER_NETWORK=supabase_default
POSTGRES_EXPORTER_USER=supabase_metrics
POSTGRES_EXPORTER_PASSWORD=<TAVO_SUGENERUOTAS_SLAPTAŽODIS>
```

Jei tikras tinklo vardas nėra `supabase_default`, pakeisk jį. Išlaikyk `.env` failo `0600` teises:

```bash
chmod 600 /srv/monitoring/.env
```

### 7. Patikrink ir paleisk exporter’į

PuTTY sesijoje vykdyk:

```bash
cd /srv/monitoring
docker compose -f compose.yaml config -q
docker compose -f compose.yaml pull postgres-exporter
docker compose -f compose.yaml up -d postgres-exporter prometheus
docker compose -f compose.yaml restart prometheus
```

Prometheus perkraunamas, kad perskaitytų atnaujintą `prometheus.yml`.

Compose konfigūracijoje exporter’io atvaizdas prisegtas prie `quay.io/prometheuscommunity/postgres-exporter:v0.20.1`. Jis prijungiamas prie esamo Supabase tinklo ir privataus stebėsenos tinklo. Hosto prievadas nepublikuojamas.

### 8. Patikrink konteinerį ir Prometheus

```bash
cd /srv/monitoring
docker compose -f compose.yaml ps postgres-exporter prometheus
docker compose -f compose.yaml logs --tail=40 postgres-exporter
```

Prisijungęs prie Grafana atidaryk **Explore**, pasirink Prometheus ir vykdyk:

```promql
up{job="postgres"}
pg_up
```

Abiejų užklausų rezultatas turėtų būti `1`. `up{job="postgres"}` patvirtina Prometheus scrape, o `pg_up` — eksportuotojo prisijungimą prie PostgreSQL.

### 9. Importuok PostgreSQL dashboard’ą į Grafaną

Grafanoje pasirink **Dashboards → New → Import**, įvesk dashboard ID **16265**, spausk **Load**, pasirink Prometheus duomenų šaltinį ir užbaik importą. Tai Grafana.com „PostgreSQL Exporter“ dashboard’as, skirtas `postgres_exporter` metrikoms.

Po importo nustatyk laikotarpį, pavyzdžiui, **Last 1 hour**. Kai Prometheus bus surinkęs kelis ciklus, patikrink jungčių, apkrovos, transakcijų, cache ir DB dydžio paneles.

## Duomenų saugojimas ir apkrova

Exporter’is statistiką skaito iš PostgreSQL ir metrikų nekaupia DB lentelėse. Laiko eilutės saugomos Prometheus Docker tome `/srv/monitoring` steke, o Grafana dashboard’o nustatymai — Grafana tome.

Esamas Prometheus stekas renka kas 30 sekundžių, saugo iki 3 dienų, o jo TSDB blokų dydžio tikslas yra 2 GB. PostgreSQL metrikos bus bendrame Prometheus saugojime, todėl dydžio riba gali būti pasiekta greičiau ir senesnė istorija pašalinta anksčiau. Ši riba nėra kietas viso Docker tomo limitas: WAL ir kompaktavimo metu gali reikėti papildomos vietos. Periodiškai tikrink VPS laisvą vietą ir Prometheus tomo faktinį dydį.

## Dažnos problemos

- **Exporter’io loguose `no such host` / connection refused:** patikrink `SUPABASE_DOCKER_NETWORK` ir ar `supabase-db` konteineris veikia tame tinkle.
- **`password authentication failed`:** SQL Editor paskyros slaptažodis turi sutapti su `POSTGRES_EXPORTER_PASSWORD` VPS `.env` faile.
- **`permission denied` peržiūroms:** patikrink, kad `supabase_metrics` turi `pg_monitor` narystę ir `CONNECT` teisę į `postgres`.
- **`function pg_stat_statements(boolean) does not exist`:** patikrink plėtinio schemą ir `USAGE` teisę. Šio projekto exporter'io prisijungime nustatytas `search_path=extensions,pg_catalog`, nes Supabase plėtinys yra `extensions` schemoje. Jo SQL tekstų rinkimas šiame diegime neįjungtas.
- **Prometheus target `down`:** patikrink `docker compose logs postgres-exporter`, tada Prometheus `postgres` scrape target būseną Grafanos Explore užklausomis `up{job="postgres"}` ir `pg_up`.

VPS rolės ir `pg_stat_statements` prieigos migracijos patvirtintos 2026-10-07 pagal vartotojo pateiktą SQL Editor vykdymą bei atskirą read-only patikrą per autorizuotą DB tunelį. Explicit connection `search_path` pakeitimas įdiegtas VPS; `up`, `pg_up` ir `pg_stat_statements_calls_total` patvirtinti. Liko importuoti Grafana dashboard'ą.
