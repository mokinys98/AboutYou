# 0 fazė — source inventorizacija ir atkuriamas backup

**Būsena:** source techninis baseline surinktas, backup dar nesukurtas  
**Pradėta:** 2026-07-15  
**Tikslas:** užfiksuoti valdomo Supabase projekto faktinę būklę ir sukurti atkuriamą backup prieš bet kokius produkcinius pakeitimus.  
**Source pakeitimai šioje fazėje:** draudžiami, išskyrus atskirai patvirtintą backup ar diagnostikos veiksmą.

## 1. Kodėl pradedame nuo šios fazės

Migracija negali prasidėti VPS diegimu. Pirmiausia reikia įrodyti, kad source duomenys yra inventorizuoti ir atkuriami. Tai apsaugo nuo trijų pagrindinių rizikų:

1. esamo katalogo / read-model incidento priežastis gali persikelti kartu su duomenimis;
2. SQL dump neperkelia fizinių Storage objektų;
3. source ir target Postgres bei Supabase servisų versijų neatitikimai gali paaiškėti tik per rehearsal restore.

0 fazės rezultatas turi būti ne vien dump failų egzistavimas, o dokumentuota inventorizacija, backup vientisumo patikra ir aiškus restore rehearsal įėjimo taškas.

## 2. 2026-07-15 atlikta read-only repozitorijos inventorizacija

Patikra atlikta neatskleidžiant `.env` reikšmių.

| Sritis | Faktas | Reikšmė migracijai |
|---|---|---|
| Supabase migracijos | Repo yra 44 SQL migracijos | Istorija naudinga auditui, bet restore source of truth bus oficialus dump |
| Dubliuoti migracijų prefiksai | `202607070001` ir `202607140001` panaudoti po du kartus | Negalima aklai perleisti istorinės migracijų sekos ant target |
| Storage | Migracijos sukuria privačius `sync-debug` ir `sync-raw` bucket'us | SQL dump perkels metaduomenis, bet objektų baitams reikės atskiro eksporto ir parity |
| DB scheduler | Numatyti `catalog-read-model-refresh` kas 5 min. ir `catalog-read-model-refresh-history-cleanup` 03:15 | Po restore job'ai turi likti išjungti iki 3–4 fazių patikrų |
| Cloudflare Worker scheduler | `17 */6 * * *`, `47 * * * *`, `*/5 * * * *` | Cutover metu šie writer'ių paleidimai turės būti kontroliuojamai sustabdyti |
| Aplikacijos integracija | Web, API ir sync naudoja `@supabase/supabase-js`; lockfile dabar fiksuoja 2.110.0 | Reikia end-to-end PostgREST, Auth ir Storage testų |
| Dependency deklaracija | Trijuose workspace `package.json` Supabase klientas deklaruotas kaip `latest` | Tai supply-chain ir pakartojamumo rizika; prieš cutover versija turi būti prisegta atskiru patvirtintu pakeitimu |
| Vietinės priemonės | Docker 29.1.3 ir Compose 2.40.3 yra; `psql` PATH'e nėra; `npx supabase` 2.109.1 veikia | Dump dar nevykdytas; CLI gali vykdyti oficialų dump gavęs pasiekiamą DB jungtį |
| Vietinė konfigūracija | `SOURCE_DATABASE_URL` yra, bet direct DB hostname pasiekiamas tik per IPv6 | Reikia pakeisti į Supabase Session pooler connection string |

### Repo migracijų ledger rizika

Dubliuoti prefiksai:

- `202607070001_product_sync_diagnostics.sql`
- `202607070001_reliable_product_detail_sync.sql`
- `202607140001_strict_lpl_filter.sql`
- `202607140001_telegram_alerts.sql`

Faktinę source schemą ir `supabase_migrations.schema_migrations` ledger privalome palyginti su repo. Šiame etape failų nepervadiname: tai galėtų iškreipti jau pritaikytų migracijų istoriją.

## 3. Oficialios Supabase gairės, aktualios šiai migracijai

Patikrinta 2026-07-15:

- nauja self-hosted Supabase instaliacija pagal nutylėjimą naudoja Postgres 17;
- Postgres 17 self-hosted image nebėra `timescaledb`, `plv8`, `plcoffee` ir `plls`, todėl source extensions sąrašas yra privalomas prieš target versijos pasirinkimą;
- nuo 2026-06-17 naujame compose Studio ir `postgres-meta` naudoja ne `supabase_admin`, o ne-superuser `postgres` rolę;
- naujuose projektuose naujos `public` lentelės automatiškai neeksponuojamos Data API: prieiga turi turėti aiškius `GRANT`, o RLS lieka atskiras apsaugos sluoksnis;
- oficialus platform → self-hosted kelias yra trys atskiri `supabase db dump` failai (`roles`, `schema`, `data`) ir restore su `psql --single-transaction`;
- `auth.users`, RLS, funkcijos ir triggeriai patenka į DB dump, bet JWT/API raktai, Auth provider konfigūracija, SMTP, DNS ir fiziniai Storage objektai perkeliami atskirai;
- seni platformos JWT po perjungimo negalios, todėl vartotojai turės prisijungti iš naujo.

Naudoti oficialūs šaltiniai:

- <https://supabase.com/docs/guides/self-hosting/restore-from-platform>
- <https://supabase.com/docs/guides/self-hosting/docker>
- <https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17>
- <https://supabase.com/changelog/46080-self-hosted-supabase-upgrading-from-pg-15-to-17-breaking-change>
- <https://supabase.com/changelog/46081-self-hosted-supabase-switching-studio-from-supabase-admin-to-postgres-breaking-c>
- <https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically>

## 4. Saugus prieigos paruošimas

Kad būtų galima tęsti, operatorius turi gauti source DB connection string iš Supabase Dashboard **Connect** lango (direct arba session pooler) ir saugiai nustatyti jį kaip `SOURCE_DATABASE_URL`. Šiame repo galima naudoti esamą vietinį `.env`: jis ignoruojamas per `.gitignore`, o jo reikšmės inventorizacijos metu nespausdinamos. Alternatyva — tik operatoriaus terminalo sesijos aplinkos kintamasis.

Connection string'o, DB slaptažodžio, service-role rakto ir dump turinio negalima:

- rašyti į šį dokumentą;
- commit'inti į repo;
- siųsti pokalbio žinute;
- palikti shell history, jei komanda jį išplėstų kaip paprastą argumentą.

Backup katalogas turi būti už repo ribų, užrakintas tik administratoriui ir šifruotas. Jo vieta bei off-host target dokumentuojami tik kaip sistemos pavadinimas / identifikatorius, ne kaip slaptas URL ar raktas.

## 5. Source DB inventorizacijos užklausos

Šias read-only užklausas reikia vykdyti kontroliuojamu metu. Jei source tuo metu nestabilus, pirmiausia vykdomos lengvos versijų ir konfigūracijos užklausos; dydžių bei aktyvumo patikros atidedamos iki saugaus lango.

```sql
show server_version;

select extname, extversion
from pg_extension
order by extname;

select n.nspname as schema_name,
       c.relname as object_name,
       c.relkind,
       pg_get_userbyid(c.relowner) as owner
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname not in ('pg_catalog', 'information_schema')
order by n.nspname, c.relname;
```

```sql
select jobid, jobname, schedule, active, database, username, command
from cron.job
order by jobid;

select jobid, status, start_time, end_time, return_message
from cron.job_run_details
order by start_time desc
limit 100;
```

```sql
select pid,
       usename,
       state,
       wait_event_type,
       wait_event,
       now() - query_start as duration,
       left(query, 300) as query
from pg_stat_activity
where state <> 'idle'
order by query_start;
```

```sql
select pg_size_pretty(pg_database_size(current_database())) as database_size;

select schemaname,
       relname,
       pg_size_pretty(pg_total_relation_size(format('%I.%I', schemaname, relname))) as total_size,
       pg_total_relation_size(format('%I.%I', schemaname, relname)) as total_bytes
from pg_stat_user_tables
order by total_bytes desc
limit 50;
```

```sql
select version
from supabase_migrations.schema_migrations
order by version;

select 'auth.users' as entity, count(*) as rows from auth.users
union all select 'public.products', count(*) from public.products
union all select 'public.offers', count(*) from public.offers
union all select 'public.catalog_items_read', count(*) from public.catalog_items_read
union all select 'public.catalog_item_facet_values_read', count(*) from public.catalog_item_facet_values_read
union all select 'public.team_members', count(*) from public.team_members;
```

```sql
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
order by id;

select bucket_id,
       count(*) as objects,
       sum(coalesce((metadata ->> 'size')::bigint, 0)) as stated_bytes
from storage.objects
group by bucket_id
order by bucket_id;
```

```sql
select singleton,
       requested_version,
       completed_version,
       requested_at,
       refresh_started_at,
       refresh_completed_at,
       last_status,
       last_duration_ms,
       last_error
from public.catalog_read_model_refresh_state;
```

Jei paskutinė užklausa neatitinka faktinės lentelės struktūros, jos laukų pavadinimai tikslinami pagal `information_schema.columns`; source schema nekeičiama.

## 6. Backup procedūra

Prieš vykdymą būtina patikrinti CLI sintaksę su `--help`, nes Supabase CLI keičiasi. Oficialus loginis backup šablonas:

```bash
npx supabase --version
npx supabase db dump --help

npx supabase db dump --db-url "$SOURCE_DATABASE_URL" -f roles.sql --role-only
npx supabase db dump --db-url "$SOURCE_DATABASE_URL" -f schema.sql
npx supabase db dump --db-url "$SOURCE_DATABASE_URL" -f data.sql --use-copy --data-only
```

Vykdyti tik užrakintame, šifruotame kataloge už repo ribų. Po dump:

1. patikrinti, kad visi trys failai egzistuoja ir nėra tušti;
2. apskaičiuoti SHA-256 ir išsaugoti checksum manifestą kartu su backup;
3. užfiksuoti CLI versiją, UTC laiką, source Postgres versiją ir failų dydžius;
4. nukopijuoti į patvirtintą šifruotą off-host target;
5. nelaikyti backup atkuriamu, kol 2 fazėje jis neatkurtas į disposable staging aplinką.

Storage objektams sudaromas atskiras manifestas su `bucket`, object key, dydžiu, MIME tipu, cache-control, atnaujinimo laiku ir, kai įmanoma, checksum / ETag. Vien `storage.objects` eilučių neužtenka.

## 7. Dar neužpildyta faktinė source ataskaita

| Patikra | Rezultatas | Būsena |
|---|---|---|
| Source Postgres versija | PostgreSQL 17.6 | Atlikta 2026-07-15 |
| Source extensions ir versijos | `pg_cron` 1.6.4, `pg_stat_statements` 1.11, `pgcrypto` 1.3, `plpgsql` 1.0, `supabase_vault` 0.3.1, `uuid-ossp` 1.1 | Atlikta; PG17 nesuderinamų extensions nerasta |
| DB dydis ir 25 didžiausios lentelės | 870 550 675 B / 830 MB; didžiausios lentelės aprašytos 7.4 skyriuje | Atlikta 2026-07-15 |
| Roles / grants / object owners | `public` 34 objektai priklauso `postgres`; Auth ir Storage objektai priklauso atitinkamoms Supabase admin rolėms; `service_role` turi 29 public lentelių grant'us | Pradinis baseline atliktas; funkcijų auditas turi stop signalų |
| `supabase_migrations` ledger | 14 įrašų, kai repo yra 44 SQL failai | Atlikta; patvirtintas ledger neatitikimas |
| pg_cron job'ai ir 7 dienų vykdymų santrauka | 2 job'ai; refresh išjungtas, cleanup įjungtas; detaliau 7.5 skyriuje | Atlikta 2026-07-15 |
| Aktyvios / laukiančios užklausos | Matavimo metu 1 active, 10 idle ir background sesijos; query tekstai nefiksuoti | Pradinis baseline atliktas |
| Pagrindinių lentelių row counts | `products` 51 535, `offers` 51 535, `auth.users` 2 | Atlikta 2026-07-15 |
| Storage bucket count / bytes | 2 privatūs bucket'ai, antro matavimo metu 682 objektai, 6 155 261 B / apie 5,87 MiB | Atlikta 2026-07-15; source tebėra aktyvus |
| Auth, SMTP, redirect ir OAuth inventorius | — | Laukiama Dashboard konfigūracijos peržiūros |
| Roles/schema/data dump | — | Laukiama DB prieigos ir šifruotos backup vietos |
| Dump SHA-256 manifestas | — | Laukiama dump |
| Off-host kopija | Cloudflare R2 Standard, EU jurisdikcija | Target pasirinktas, bucket ir prieigos raktai dar nesukurti |

### 7.1. 2026-07-15 DB dydžio matavimo bandymas

- `.env` faile `SOURCE_DATABASE_URL` rastas; jo reikšmė nebuvo atspausdinta.
- Patikrintas `npx supabase` CLI: 2.109.1.
- Read-only dydžio SQL neprisijungė prie DB, duomenys nebuvo pakeisti.
- Diagnostika parodė, kad pateiktas direct DB hostname turi tik IPv6 (`AAAA`) adresą, o ši vykdymo aplinka jo 5432 porto nepasiekia.
- Tęsimui `SOURCE_DATABASE_URL` reikia pakeisti Supabase Dashboard → **Connect** pateikiamu **Session pooler** connection string. Jo hostname paprastai baigiasi `.pooler.supabase.com`, tačiau konkretus adresas turi būti kopijuojamas iš Dashboard, o ne spėjamas.

### 7.2. Pasirinktas off-host backup target

**Sprendimas:** naudoti privatų Cloudflare R2 bucket'ą `aboutyou-supabase-backups`, pasirinkus:

- storage class: **Standard**;
- jurisdiction: **European Union (`eu`)**;
- public access ir `r2.dev`: išjungti;
- API token: apribotas tik šiuo bucket'u;
- failai: suspausti, tada užšifruoti kliento pusėje prieš upload;
- retention: 7 daily + 4 weekly + 3 monthly, valdoma aiškiais prefiksais ir lifecycle taisyklėmis;
- bent vienas periodinis restore testas; R2 objekto egzistavimas savaime nėra atkuriamumo įrodymas.

R2 automatiškai šifruoja visus objektus ir metaduomenis AES-256 ramybės būsenoje bei naudoja TLS perdavimo metu. Papildomas kliento pusės šifravimas paliekamas todėl, kad DB dump yra jautrus ir jame yra Auth bei produkto duomenų.

### 7.3. Ar pakaks R2 Free limito

2026-07-15 Cloudflare R2 Standard nemokamai suteikia per mėnesį:

- 10 GB-month saugojimo;
- 1 mln. Class A operacijų;
- 10 mln. Class B operacijų;
- nemokamą egress.

Backup scenarijuje operacijų limitų beveik tikrai pakaks. Pagrindinis limitas yra 10 GB-month talpa. Su 14 pilnų DB kopijų retention apytikslė reikalinga vieta yra:

```text
R2 vieta ≈ 14 × vieno suspausto ir užšifruoto DB backup dydis
           + viena aktuali Storage objektų kopija / delta istorija
           + manifestai ir nedidelis rezervas
```

Jei Storage objektų kopijai laikinai neskaičiuotume vietos, 10 GB limitas reiškia, kad vienas pilnas suspaustas DB backup turi būti ne didesnis kaip maždaug 0,71 GB. Praktiniai pavyzdžiai:

| Vienas suspaustas DB backup | 14 kopijų | Free limito situacija prieš Storage objektus |
|---:|---:|---|
| 0,25 GB | 3,5 GB | saugus rezervas |
| 0,50 GB | 7 GB | tikėtina, kad tilps, jei Storage mažas |
| 0,70 GB | 9,8 GB | praktiškai nebelieka rezervo |
| 1 GB | 14 GB | viršys free maždaug 4 GB |
| 2 GB | 28 GB | viršys free maždaug 18 GB |
| 5 GB | 70 GB | viršys free maždaug 60 GB |

Viršijimas nėra brangus: R2 Standard saugojimas kainuoja 0,015 USD už GB-month virš nemokamo limito. Pavyzdžiui, 28 GB bendra apimtis reikštų apie 0,27 USD/mėn. už 18 apmokestinamų GB, neįskaičiuojant Cloudflare apvalinimo ir galimų papildomų operacijų.

**Tarpinė išvada:** R2 Free labai realiai gali tikti pradžiai, bet galutinį atsakymą pateiksime tik išmatavę DB, sugeneravę pirmą suspaustą dump ir suskaičiavę `sync-debug` bei `sync-raw` objektų baitus.

### 7.4. Faktinė 2026-07-15 talpa

Source DB fizinis dydis yra **830 MB**, o visi Storage objektai sudaro tik apie **5,87 MiB**:

| Bucket | Objektai | Baitai | Apytikslis dydis | Public |
|---|---:|---:|---:|---|
| `sync-debug` | 6 | 845 939 | 826 KiB | ne |
| `sync-raw` | 676 | 5 309 322 | 5,06 MiB | ne |
| **Iš viso** | **682** | **6 155 261** | **5,87 MiB** | — |

Pirmas bendras matavimas kelios minutės anksčiau rodė 681 objektą ir 6 147 317 baitų. Vieno objekto skirtumas patvirtina, kad source matavimo metu tebėra aktyvus ir priima write'us. Final parity skaičiai turi būti imami tik cutover freeze lange.

Didžiausi DB objektai:

| Objektas | Apytikslės eilutės | Fizinis dydis |
|---|---:|---:|
| `public.catalog_items_read` | 47 368 | 219 MB |
| `public.catalog_item_facet_values_read` | 1 054 836 | 141 MB |
| `public.products` | 51 535 | 117 MB |
| `public.product_detail_sections` | 188 722 | 105 MB |
| `public.product_size_options` | 285 009 | 60 MB |
| `public.product_color_options` | 173 591 | 35 MB |
| `public.daily_prices` | 220 101 | 34 MB |
| `public.product_detail_sync` | 51 535 | 29 MB |
| `public.product_categories` | 197 860 | 28 MB |
| `public.price_changes` | 125 684 | 20 MB |

Du read-model objektai kartu užima apie **360 MB**, arba maždaug 43 % visos DB. Tai svarbu tiek backup dydžiui, tiek 250k apkrovos projekcijai.

Net konservatyviai skaičiuojant visą dabartinį 830 MB DB dydį kiekvienai iš 14 kopijų, gautume apie 11,6 GB prieš suspaudimą. Kadangi loginis SQL dump bus suspaustas, o Storage sudaro tik apie 6 MB, **R2 10 GB Free limitas dabartinei apimčiai tikėtinai pakaks**. Galutinis skaičius bus fiksuojamas pagal pirmo realaus suspausto ir užšifruoto backup failo dydį.

### 7.5. Refresh, cron ir WAL baseline

`pg_cron` faktinė būsena:

| Job | Grafikas | Active | 7 dienų rezultatas |
|---|---|---:|---|
| `catalog-read-model-refresh` | `*/5 * * * *` | ne | 210 succeeded, 12 failed |
| `catalog-read-model-refresh-history-cleanup` | `15 3 * * *` | taip | 1 succeeded |

Refresh state 2026-07-15:

- `requested_version = 32`;
- `completed_version = 24`;
- neapdorotas skirtumas: 8 versijos;
- `last_status = pending`;
- paskutinio užbaigto bandymo trukmė: 120 297 ms;
- paskutinė klaida: `57014: canceling statement due to statement timeout`;
- periodinis refresh job'as dabar išjungtas.

Tai yra **stop signalas automatiniam refresh įjungimui target aplinkoje**. Rehearsal restore turi importuoti cron kontroliuojamai ir neaktyvuoti refresh, kol neįdiegtas circuit breaker bei neatliktas apkrovos testas.

`pg_stat_wal` nuo 2026-06-30 statistikos atstatymo užfiksavo apie **28 GB WAL** (`30 267 025 721` baitą). Tai nėra tuo metu diske laikomo WAL dydis, bet yra aiškus write amplification / refresh aktyvumo baseline, kurį reikės palyginti su staging.

### 7.6. Migracijų ledger neatitikimas

Source `supabase_migrations.schema_migrations` turi tik 14 versijų, o repo kataloge yra 44 SQL failai. Be to, keturios source ledger versijos neturi tokio paties pavadinimo failų repo:

- `20260713110946`
- `20260713111346`
- `20260713111604`
- `20260713111722`

Tai patvirtina plano taisyklę: target schema atkuriama iš oficialaus source dump, o ne aklai perleidžiant repo migracijas. Atskiras švarus future migration baseline sprendžiamas tik po restore parity.

### 7.7. Pradinis RLS patikrinimas

Read-only katalogų patikra nerado nė vienos paprastos ar partitioned `public` lentelės su išjungtu RLS. Tai teigiamas pradinis signalas, tačiau pilnas policy, grants, funkcijų ir `SECURITY DEFINER` auditas dar nebaigtas.

### 7.8. Roles, grants ir `SECURITY DEFINER` stop signalai

Objektų ownership baseline:

- 34 `public` schemos lentelių, view, materialized view ir sequence objektai priklauso `postgres`;
- 24 `auth` objektai priklauso `supabase_auth_admin`;
- 8 `storage` objektai priklauso `supabase_storage_admin`;
- `service_role` turi po 29 `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `REFERENCES`, `TRIGGER` ir `TRUNCATE` grant'us `public` lentelėms;
- `pg_policies` negrąžino `public` policy įrašų. Esant įjungtam RLS tai reiškia default-deny paprastoms klientų rolėms, o aplikacijos DB darbą daugiausia atlieka `service_role` per Worker.

Rastos keturios `public` schemos `SECURITY DEFINER` funkcijos, kurias gali vykdyti `PUBLIC`:

| Funkcija | Papildomi grants | Rizika, kurią reikia patikrinti |
|---|---|---|
| `catalog_news_facets(jsonb)` | `anon`, `authenticated`, `service_role` | Gali būti sąmoningas viešas read endpoint, bet reikia patikrinti search path ir duomenų ribas |
| `cleanup_price_history()` | `service_role` | `PUBLIC` neturi turėti galimybės paleisti destructive cleanup be aiškaus pagrindimo |
| `finish_sync_run(uuid, sync_run_status, integer, integer, text)` | `service_role` | `PUBLIC` galėtų keisti sync būseną, jei PostgREST eksponuoja funkciją |
| `record_price_observation(uuid, integer, integer, integer, char)` | `service_role` | `PUBLIC` galėtų inicijuoti privileged price write logiką |

Šiame etape grants nekeičiami. Prieš rehearsal restore reikia peržiūrėti faktinius funkcijų body, `search_path`, vidinį autorizavimą ir PostgREST pasiekiamumą. Jei vieša prieiga nereikalinga, pataisa turi būti atskira audituota migracija su `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated` ir tiksliniu `GRANT ... TO service_role`.

## 8. Sprendimai ir įėjimo duomenys, kurių reikia tęsimui

- [x] `SOURCE_DATABASE_URL` pakeistas į iš šios aplinkos pasiekiamą Supabase **Session pooler** connection string.
- [ ] Patvirtinta šifruota lokali backup staging vieta už repo ribų.
- [x] Patvirtintas off-host backup target ir retention: Cloudflare R2 Standard, EU, 7 daily + 4 weekly + 3 monthly.
- [ ] Sukurtas privatus R2 bucket ir tik jam apribotas API token.
- [x] Read-only DB diagnostika atlikta; produkciniai duomenys nekeisti.
- [ ] Nurodytas saugus langas pilnam roles/schema/data dump.
- [ ] Patvirtinta, kas gali peržiūrėti Auth / SMTP / redirect / OAuth konfigūraciją Dashboard'e.

Slaptų reikšmių į šį failą ar pokalbį pateikti nereikia.

## 9. 0 fazės stop / go vartai

Kol kas statusas yra **STOP**. Į 1 fazę galima eiti tik kai:

- [x] užfiksuotos source versijos, extensions, roles, grants, cron ir migracijų ledger; rastos saugos rizikos perkeltos į privalomą auditą;
- [x] užfiksuoti pagrindinių lentelių bei Storage objektų skaičiai ir dydžiai;
- [ ] sukurti roles, schema ir data dump;
- [ ] dump turi SHA-256 manifestą ir šifruotą off-host kopiją;
- [ ] Auth / SMTP / redirect / OAuth konfigūracija inventorizuota be secret'ų;
- [ ] sutarta, kad tikrasis atkuriamumo įrodymas bus 2 fazės rehearsal restore.

## 10. Kitas veiksmas

Paruošti privatų R2 bucket, tik jam apribotą API token ir šifruotą lokalią staging vietą. Tada saugiu dump langu sukurti oficialų trijų dalių backup, jį suspausti, užšifruoti, apskaičiuoti SHA-256, įkelti į R2 ir patikrinti objektų dydžius bei checksum manifestą. Tik po Auth konfigūracijos inventoriaus galima uždaryti 0 fazę ir pradėti Contabo staging platformą.
