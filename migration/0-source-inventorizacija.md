# 0 fazė — source inventorizacija ir atkuriamas backup

## Progreso varnelės — atnaujinti pirmiausia

- [x] Source inventorizacija ir DB/Storage dydžių baseline.
- [x] Roles/schema/data dump sukurtas, SHA-256 patikrintas.
- [x] `age` šifravimas ir privatus identity escrow.
- [x] Privatus Cloudflare R2 bucket, retention ir off-host restore patikra.
- [x] R2 API token apribotas bucket’ui ir įdiegtas VPS secret faile.
- [x] Auth, redirect, OAuth ir SMTP Dashboard inventorius.
- [x] Resend DKIM/SPF/MX DNS `Verified`.
- [x] Supabase Custom SMTP išsaugotas; reset-password laiškas `Delivered`.
- [x] Recovery redirect pasiekia Pages aplikaciją.
- [ ] Aplikacijoje įdiegta recovery UI / `PASSWORD_RECOVERY` logika.
- [x] R2 connectivity testas iš VPS; bucket listing sėkmingas per `/etc/aboutyou-backup/r2.env`.
- [ ] 2 fazės restore rehearsal ir parity ataskaita.

**Būsena:** source baseline, šifruotas dump, patikrinta off-host R2 kopija, retention, VPS backup secret, privataus `age` rakto escrow, Auth URL/provider inventorizacija, Resend DNS ir VPS R2 connectivity paruošti; Supabase Custom SMTP išsaugotas, reset-password laiškas pristatytas ir redirect pasiekia Pages aplikaciją, tačiau recovery UI logikos nėra.
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
| Auth, SMTP, redirect ir OAuth inventorius | Dashboard būsena užfiksuota be secret'ų; Resend DNS įrašai pridėti ir patvirtinti; atliktas reset-password siuntimo testas | Atlikta; Custom SMTP išsaugotas, DNS `Verified`, Resend `Delivered` |
| Roles/schema/data dump | Sukurtas 2026-07-15 19:24:42 UTC, suspaustas ir užšifruotas | Atlikta; tai baseline backup, ne final cutover dump |
| Dump SHA-256 manifestas | Šio dokumento 7.9 skyriuje | Atlikta ir patikrinta bandomu iššifravimu |
| Off-host kopija | Cloudflare R2 Standard, EU jurisdikcija | Atlikta; objektas parsisiųstas atgal ir jo SHA-256 sutapo |

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

**Išvada po pirmo realaus dump:** R2 Free dabartinei apimčiai pakanka su dideliu rezervu. Vienas užšifruotas dump yra 48 710 800 B, todėl 14 tokių kopijų užimtų apie 682 MB. Pridėjus dabartinius maždaug 6 MB Storage objektų, manifestus ir rezervą, bendra apimtis lieka gerokai mažesnė už 10 GB-month.

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

### 7.9. 2026-07-15 šifruoto backup įrodymas

Naudotos priemonės:

- Supabase CLI: 2.109.1;
- source Postgres image, kurį oficialiai pasirinko CLI: `public.ecr.aws/supabase/postgres:17.6.1.143`;
- šifravimas: `age` 1.3.1;
- atsisiųsto `age-v1.3.1-windows-amd64.zip` SHA-256: `c56e8ce22f7e80cb85ad946cc82d198767b056366201d3e1a2b93d865be38154`;
- `age` public recipient: `age1tuan0m5fzq62f22z5kwmqewrd07vvknveurq0nulpx46t7ktqgrqghysvg`.

Privatus `age` identity sukurtas už repo ribų ir jo ACL palikta tik dabartiniam Windows naudotojui:

```text
C:\Users\Auris\Documents\AboutYouMigrationSecrets\age-identity.txt
```

Privataus rakto turinys nebuvo spausdintas, commit'intas ar įtrauktas į šį dokumentą. Prieš 0 fazės uždarymą jo kopija turi būti patalpinta į savininko password manager arba kitą nepriklausomą secret escrow. Vien lokali kopija nėra pakankamas recovery sprendimas.

Oficialaus dump plaintext dydžiai prieš suspaudimą:

| Failas | Dydis |
|---|---:|
| `roles.sql` | 297 B |
| `schema.sql` | 142 853 B |
| `data.sql` | 290 585 620 B |

Galutinis užšifruotas artefaktas laikomas už repo ribų:

```text
C:\Users\Auris\Documents\AboutYouMigrationBackups\aboutyou-supabase-20260715T192442Z.tar.gz.age
```

| Patikra | Rezultatas |
|---|---|
| Užšifruoto failo dydis | 48 710 800 B |
| Užšifruoto failo SHA-256 | `8d87e2f8be1caac1fe2c410021cdc1d18ffb3ebd6d8386619d90fce134d3c1b9` |
| Iššifruoto `tar.gz` dydis | 48 698 712 B |
| Iššifruoto `tar.gz` SHA-256 | `e20fb194d0c2fa59dab3257785ee6793be2f5aad382b301f28faf7d5454254e2` |
| Bandomasis iššifravimas | sėkmingas |
| `tar.gz` integralumo patikra | sėkminga |
| Archyvo nariai | tik `roles.sql`, `schema.sql`, `data.sql` |
| Plaintext temp failai | po patikros pašalinti |

Šis backup sukurtas aktyvioje source sistemoje ir yra loginio snapshot baseline kopija. Final cutover metu vis tiek reikės naujo dump po writer freeze.

### 7.10. 2026-07-15 patikrinta off-host R2 kopija

Po R2 aktyvavimo su Wrangler 4.107.0 sukurtas bucket ir patikrinta jo faktinė konfigūracija:

| Parametras | Faktinis rezultatas |
|---|---|
| Bucket | `aboutyou-supabase-backups` |
| Jurisdikcijos argumentas | `eu` |
| Cloudflare parodyta vieta | `EEUR` |
| Numatytoji storage class | `Standard` |
| Sukūrimo laikas | 2026-07-15 19:30:57 UTC |
| Vieša prieiga per `r2.dev` | išjungta |

Užšifruotas baseline backup įkeltas kaip privatus objektas:

```text
baseline/20260715T192442Z/aboutyou-supabase-20260715T192442Z.tar.gz.age
```

| Patikra | Rezultatas |
|---|---|
| Upload | sėkmingas |
| Storage class | `Standard` |
| Parsisiųstos kopijos dydis | 48 710 800 B |
| Parsisiųstos kopijos SHA-256 | `8d87e2f8be1caac1fe2c410021cdc1d18ffb3ebd6d8386619d90fce134d3c1b9` |
| Sutapimas su lokaliu šifruotu artefaktu | taip |
| Laikina verifikacijos kopija | po patikros pašalinta |

Pirmas nesėkmingas bandymas prieš R2 aktyvavimą grąžino `10042`; pakartojus po aktyvavimo bucket kūrimas ir upload buvo sėkmingi. Į R2 pateko tik kliento pusėje `age` užšifruotas failas — plaintext SQL dump nebuvo siunčiamas.

Sukurtos ir patikrintos retention taisyklės:

| Taisyklė | Prefiksas | Veiksmas |
|---|---|---|
| `daily-7d` | `daily/` | objektai baigiasi po 7 dienų |
| `weekly-28d` | `weekly/` | objektai baigiasi po 28 dienų |
| `monthly-90d` | `monthly/` | objektai baigiasi po 90 dienų |

Wrangler taip pat automatiškai pridėjo nebaigtų multipart upload'ų nutraukimą po 7 dienų. Dabartinis baseline objektas sąmoningai laikomas `baseline/` prefikse ir į šias retention taisykles nepatenka.

Automatiniams būsimiems backup sukurtas tik šiam bucket apribotas API token. Jo reikšmės saugomos password manager’yje ir VPS root-only secret faile; į repo ar šį dokumentą jos nepatenka.

### 7.11. 2026-07-15 Auth, SMTP, redirect ir OAuth repo inventorizacija

Repo dalis atlikta read-only. 2026-07-15 Dashboard būseną pateikė operatorius; source nustatymai nebuvo keičiami.

#### Auth srautai, rasti kode

| Srautas | Repo faktas | Reikalinga Dashboard būsena |
|---|---|---|
| El. paštas + slaptažodis | `apps/web/pages/login.vue` naudoja `signInWithPassword` | Email provider įjungtas |
| Magic link | `signInWithOtp`, `shouldCreateUser: false` | Email OTP / passwordless leidžiamas; vieša registracija išjungta |
| Komandos kvietimas | API naudoja `auth.admin.inviteUserByEmail` su `redirectTo` | Tik administratorius gali kviesti; kvietimo laiškas įjungtas |
| Sesija | Web naudoja `getSession`, `getUser`, `onAuthStateChange` ir `exchangeCodeForSession` | Session/refresh politika turi būti suderinama su aplikacija |
| Social OAuth | Repo nerasta `signInWithOAuth` ir social provider integracijos | Visi nenaudojami social/OIDC provider'iai turi būti išjungti |
| Anonymous sign-in | Repo srauto nėra | Turi būti išjungtas |

Operatoriaus pateikta faktinė Dashboard būsena:

| Nustatymas | Būsena |
|---|---|
| Email provider | Įjungtas |
| Allow new users to sign up | Išjungtas — patvirtinta po Dashboard pakeitimo |
| Anonymous sign-ins | Išjungti |
| Confirm email | Įjungtas |
| Custom SMTP | Įjungtas ir išsaugotas; slaptažodis dokumentacijoje nefiksuojamas |
| Confirm sign up email template | Yra; naudojamas Supabase default template, kol šablonas atskirai nepakeistas |
| Social/OAuth provideriai | Išjungti |
| OAuth Server / OAuth Apps | OAuth Server išjungtas; OAuth Apps nerasta |
| Confirm email | Įjungta — patvirtinta |
| Site URL | `https://aboutyou-private-catalog-web.pages.dev` — patvirtinta |
| Redirect URLs | 4 URL — visi repo matricoje ir Dashboard sąraše, patvirtinta |

Vieša registracija dabar išjungta, todėl Dashboard būsena sutampa su repo dokumentuotu invite-only modeliu.

Papildoma password politikos būsena: minimum 6 simboliai, papildomi password requirements nenustatyti. Invite puslapio kodas pats reikalauja bent 8 simbolių, tačiau bendrą Supabase provider politiką prieš production reikia suvienodinti ir sustiprinti.

README nurodo, kad viešas naudotojų registravimasis turi likti išjungtas; tai turi būti patikrinta **Authentication → Providers → Email**. Supabase bendroje Auth konfigūracijoje atskirai valdomi naujų naudotojų registracija, email confirmation ir anonymous sign-ins. [Auth konfigūracija](https://supabase.com/docs/guides/auth/general-configuration)

#### Redirect / Site URL matrica

Kodas naudoja `location.origin`, todėl magic link callback kelias yra `<leistinas-origin>/auth/callback`. Kvietimo API naudoja `WEB_APP_URL` ir prideda `/auth/invite`. Repo deklaruoja:

```text
http://localhost:3000/auth/callback
http://localhost:3000/auth/invite
https://aboutyou-private-catalog-web.pages.dev/auth/callback
https://aboutyou-private-catalog-web.pages.dev/auth/invite
```

Dashboard reikia patikrinti **Authentication → URL Configuration**:

- Site URL patvirtintas kaip `https://aboutyou-private-catalog-web.pages.dev`;
- Redirect URLs turi visus keturis aukščiau nurodytus tikslius URL;
- neturi būti plataus `*` wildcard, kuris leistų neplanuotus redirect'us.

Supabase nurodo, kad `redirectTo` turi sutapti su leidžiamų Redirect URLs sąrašu, o Site URL naudojamas kaip numatytasis redirect. [Redirect URLs gairės](https://supabase.com/docs/guides/auth/redirect-urls)

#### SMTP ir email templates

Repo dokumentacija numato production **Resend Custom SMTP**, atskirą siuntimo subdomeną, SPF/DKIM/DMARC ir išjungtą Resend link tracking. Dashboard reikia užfiksuoti tik būseną, be SMTP slaptažodžio:

- ar įjungtas Custom SMTP ir koks siuntėjo adresas;
- ar siuntėjo domenas turi SPF, DKIM ir DMARC;
- ar Auth email template'ai (`Invite user`, magic link / confirmation) naudoja teisingą redirect kintamąjį;
- ar Invite user template tekstas atitinka repo dokumentuotą variantą.

Supabase default SMTP skirtas bandymams ir turi gavėjų bei siuntimo limitus, todėl production srautams reikia Custom SMTP. [Custom SMTP gairės](https://supabase.com/docs/guides/auth/auth-smtp)

#### Dashboard patikros lapas

Šie punktai pažymimi tik po realios Dashboard peržiūros:

- [x] Email provider įjungtas;
- [x] vieša registracija išjungta;
- [x] anonymous sign-ins išjungti;
- [x] email confirmation įjungta;
- [x] Site URL ir visi keturi Redirect URLs sutampa su repo matrica;
- [x] Custom SMTP įjungtas ir išsaugotas; siuntėjo domeno DNS autentifikacija patvirtinta;
- [x] nenaudojami social/OIDC provider'iai išjungti;
- [ ] Invite user ir magic-link template'ai patikrinti.

### 7.12. Production SMTP pasirinkimai

Supabase default SMTP paliekamas tik testams; production magic link, invite ir confirmation laiškams reikia Custom SMTP. Tiekėjas turi leisti naudoti atskirą siuntimo subdomeną su SPF, DKIM ir DMARC. [Supabase Custom SMTP gairės](https://supabase.com/docs/guides/auth/auth-smtp)

| Variant | Pliusai | Minusai | Kaina / tinkamumas |
|---|---|---|---|
| **1. Resend — rekomenduojamas** | Paprasta DNS ir SMTP konfigūracija, aiškus transactional email fokusas, tinka Supabase Auth | Free planas turi 100 laiškų per dieną limitą; production reikės stebėti quota | Free: iki 3 000/mėn.; Pro: 50 000/mėn. už 20 USD. Šiam projektui pradžiai pakanka Free, jei laiškų nedaug. [Resend SMTP](https://resend.com/docs/send-with-smtp), [kainos](https://resend.com/pricing) |
| **2. Postmark** | Labai stiprus transactional email fokusas, geri delivery įrankiai ir message streams | Brangesnis mažam projektui; Free planas tik 100 laiškų/mėn. | Basic nuo 15 USD/mėn. už 10 000 laiškų. [Postmark SMTP](https://postmarkapp.com/developer/user-guide/send-email-with-smtp), [kainos](https://postmarkapp.com/pricing) |
| **3. Amazon SES** | Mažiausia kintama kaina didesnėms apimtims, AWS IAM ir regionų kontrolė | Daugiausia paruošimo: AWS paskyra, domain identity, SMTP credentials, sandbox/production approval ir regiono pasirinkimas | Geriausias didelėms apimtims arba jei jau naudojamas AWS; SMTP kredencialai yra atskiri nuo AWS access keys. [SES SMTP credentials](https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html) |

#### Rekomenduojamas sprendimas

Pasirinkti **Resend** ir naudoti atskirą siuntimo subdomeną, pvz. `auth.<jūsų-domenas>`. DNS pusėje reikės SPF, DKIM ir DMARC; Resend SMTP naudoja `smtp.resend.com`, vartotoją `resend` ir API raktą kaip SMTP slaptažodį. STARTTLS rekomenduojamas per 587 prievadą. [Resend SMTP kredencialai](https://resend.com/docs/send-with-smtp)

Supabase Dashboard’e po domeno patvirtinimo bus įvedami tik SMTP host, port, username, password, sender name ir sender email. SMTP slaptažodis į Git ar šį dokumentą nepatenka; jį laikome password manager’yje ir VPS secret saugykloje.

Tiekėjas pasirinktas, DNS patvirtintas ir Supabase Custom SMTP išsaugotas. Production SMTP vartų likęs įrodymas yra realus invite / confirmation / magic-link testas su gavėjo pašto dėžute.

### 7.13. Nemokamo siuntimo domeno pasirinkimas

Resend reikalauja domeno, kurį valdome ir kuriame galime pridėti SPF bei DKIM DNS įrašus. [Resend domenų verifikacija](https://resend.com/docs/dashboard/domains/introduction)

| Variant | Ar tinka production? | Pastaba |
|---|---|---|
| `aboutyou-private-catalog-web.pages.dev` | Ne | Tai bendras Cloudflare Pages subdomenas; DNS zonos ir domeno ownership Resend verifikacijai nekontroliuojame |
| `resend.dev` | Ne | Resend leidžia juo siųsti tik testinius laiškus į savo Resend paskyros adresą. [Resend testavimo apribojimas](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain) |
| `*.eu.org` | Tik eksperimentui / staging | EU.org suteikia nemokamus subdomenus, tačiau nėra support/SLA ir tai nėra nuosavas registruotas domenas. Gali reikėti laukti delegavimo ir Resend gali vertinti reputaciją kaip shared domain. [EU.org](https://nic.eu.org/) |
| Pigus nuosavas domenas | Taip — rekomenduojama | Vienkartinė metinė registracijos kaina suteikia pilną DNS ownership, stabilią siuntėjo reputaciją ir lengvą providerio keitimą |

**Sprendimas:** nemokamą `EU.org` variantą galima naudoti tik staging bandymui. Production Auth laiškams reikia nuosavo domeno, pvz. `aboutyou.lt` arba kito savininko pasirinkto domeno, o siuntimui naudoti atskirą subdomeną `auth.<domenas>`.

2026-07-15 kainų palyginimas pagal viešą Spaceship kainoraštį:

| TLD | Pirma registracija | Renewal | Vertinimas |
|---|---:|---:|---|
| `.com` | apie 8,88 USD | apie 9,98 USD/metus | Rekomenduojamas: gera reputacija ir maža ilgalaikė kaina |
| `.xyz` | apie 1,86 USD | apie 12,52 USD/metus | Atsarginis pigus variantas, bet silpnesnė reputacija |
| `.online` | apie 0,98 USD | apie 21,38 USD/metus | Tik akcija; ilgalaikėje perspektyvoje brangesnis |
| `.shop` | apie 0,70 USD | apie 31,05 USD/metus | Netinka vien SMTP domenui dėl brangaus renewal |

Šaltinis: [Spaceship domain prices](https://www.spaceship.com/domains/). Galutinė kaina priklauso nuo konkretaus domeno availability, akcijos, mokesčių ir premium statuso. **Pasirinktas ir vartotojo nupirktas domenas:** `rinkissaupigiausia.online`. SMTP siuntimui bus naudojamas atskiras subdomenas `auth.rinkissaupigiausia.online`; pagrindinis domenas nėra naudojamas kaip aplikacijos Site URL. `.online` renewal kaina yra didesnė nei `.com`, todėl būtina įjungti auto-renew ir užfiksuoti renewal kainą registratoriaus paskyroje.

#### Resend DNS progreso įrašas

2026-07-15 Hostinger DNS zonoje pridėti tiksliai Resend pateikti įrašai:

| Tipas | Name | Paskirtis | Būsena Resend |
|---|---|---|---|
| TXT | `resend._domainkey.auth` | DKIM | `Verified` |
| TXT | `send.auth` | SPF | `Verified` |
| MX (priority 10) | `send.auth` | SPF bounce serveris | `Verified` |

TTL `14400` yra galiojantis, tačiau gali pailginti DNS sklaidą. Resend DKIM, SPF ir MX įrašai patikrinti ir rodo `Verified`. Receiving funkcija palikta išjungta, nes ji SMTP siuntimui nereikalinga.

DMARC yra neprivalomas, bet production'ui rekomenduojamas pagal Resend pateiktą reikšmę (`TXT _dmarc`, `v=DMARC1; p=none;`). Jo nepridėjimas nestabdo DKIM/SPF verifikacijos.

#### 2026-07-16 Custom SMTP ir recovery redirect testas

Supabase Auth išsiuntė `Reset your password` laišką į testinę Gmail dėžutę. Resend **Emails → Sending** įraše laiško būsena yra `Delivered`, o laiškas realiai gautas Gmail Inbox. Tai patvirtina SMTP kredencialų, DNS autentifikacijos ir siuntimo domeno veikimą.

`Reset password` nuoroda grąžino į `https://aboutyou-private-catalog-web.pages.dev/` su Supabase recovery fragmentu. Redirect veikia, tačiau aplikacija neturi logikos, kuri apdorotų recovery būseną ir parodytų naujo slaptažodžio formą. Tokeno URL į Git, dokumentus ar pokalbį nekeliame; paskelbta nuoroda turi būti laikoma kompromituota ir jos sesiją reikia atšaukti / iš naujo išsiųsti testinį laišką.

0 fazės stop signalas: SMTP transportas patvirtintas, bet Auth recovery vartotojo sąsajos ir fragmento apdorojimo dar nėra. Prieš staging reikia įdiegti ir su testine paskyra patikrinti `PASSWORD_RECOVERY` srautą bei naujo slaptažodžio nustatymą.

## 8. Sprendimai ir įėjimo duomenys, kurių reikia tęsimui

- [x] `SOURCE_DATABASE_URL` pakeistas į iš šios aplinkos pasiekiamą Supabase **Session pooler** connection string.
- [x] Patvirtinta šifruota lokali backup vieta už repo ribų: `C:\Users\Auris\Documents\AboutYouMigrationBackups`.
- [x] Privatus `age` identity nukopijuotas į savininko password manager / nepriklausomą secret escrow.
- [x] Patvirtintas off-host backup target ir retention: Cloudflare R2 Standard, EU, 7 daily + 4 weekly + 3 monthly.
- [x] Sukurtas privatus R2 bucket, patikrinta išjungta `r2.dev` prieiga ir įkelta verifikuota off-host kopija.
- [x] Sukurtas tik šiam R2 bucket apribotas API token būsimiems automatiniams backup; raktai išsaugoti password manager’yje ir VPS secret faile.
- [x] Sukurtos ir patikrintos `daily/`, `weekly/`, `monthly/` retention taisyklės (7 / 28 / 90 dienų).
- [x] Read-only DB diagnostika atlikta; produkciniai duomenys nekeisti.
- [ ] Nurodytas saugus langas pilnam roles/schema/data dump.
- [x] Patvirtinta, kas gali peržiūrėti Auth / SMTP / redirect / OAuth konfigūraciją Dashboard'e.

Slaptų reikšmių į šį failą ar pokalbį pateikti nereikia.

## 9. 0 fazės stop / go vartai

Kol kas statusas yra **STOP**. Į 1 fazę galima eiti tik kai:

- [x] užfiksuotos source versijos, extensions, roles, grants, cron ir migracijų ledger; rastos saugos rizikos perkeltos į privalomą auditą;
- [x] užfiksuoti pagrindinių lentelių bei Storage objektų skaičiai ir dydžiai;
- [x] sukurti roles, schema ir data dump;
- [x] dump turi SHA-256 įrodymą ir šifruotą off-host R2 kopiją, patikrintą parsisiuntimu;
- [x] Auth / SMTP / redirect / OAuth konfigūracija inventorizuota be secret'ų;
- [ ] sutarta, kad tikrasis atkuriamumo įrodymas bus 2 fazės rehearsal restore.

## 10. Kitas veiksmas

Privatus `age` identity ir R2 API tokenas jau išsaugoti password manager’yje; R2 tokenas taip pat įdiegtas VPS secret faile. Supabase Auth, SMTP, redirect bei OAuth būsena jau inventorizuota; Resend DNS įrašai patvirtinti, reset-password laiškas realiai pristatytas, redirect pasiekia Pages aplikaciją, o VPS R2 connectivity testas sėkmingas. Liko recovery UI logika aplikacijoje. Tikrasis atkuriamumo įrodymas bus 2 fazės rehearsal restore.
