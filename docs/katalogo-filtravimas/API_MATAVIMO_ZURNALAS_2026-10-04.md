# Katalogo facetų API matavimo žurnalas (2026-10-04)

## Matavimo tikslas ir būdas

Tikras `GET /v1/catalog/facets` cache miss / hit HTTP p50 ir p95, naudojant prisijungusią sesiją. Matuojamas visas API atsakymas, o DB cache būklė prieš ir po užklausos patvirtinama tik skaitymo režimu. Užklausos vykdomos nuosekliai, pradedant 12 porų bandomąja serija (po 2 šešioms grupėms), vėliau siekiant 120 porų (po 20 grupei). Atsakymų laikai ir klaidos rašomi į atskirą JSONL failą; prisijungimo žetonas ten nepatenka.

- Scenarijų generatorius ir matuoklis: [catalog_facets_api.py](../../scripts/benchmarks/catalog_facets_api.py).
- Užfiksuoti 240 atsarginių kandidatų: [API_SCENARIJAI_2026-10-04.json](API_SCENARIJAI_2026-10-04.json). Scenarijai paimti iš 12 000 deterministiškai atrinktų realių katalogo produktų; manifestas saugo katalogo versiją, filtrus ir tikslų DB cache raktą.
- Katalogo refresh būklės skaitymo režimo užklausa: [verify_catalog_refresh_read_only.sql](../../supabase/tests/verify_catalog_refresh_read_only.sql).
- Jei reikia tikslesnės cron istorijos, SQL Editor vykdoma tik skaitymo režimo [cron diagnostika](../../supabase/tests/diagnose_catalog_refresh_cron_read_only.sql).
- Vietinė manifestų patikra: `apps/api/src/catalog-benchmark-manifest.test.ts` palygina visų 240 URL API parsavimą su išsaugotais cache raktais.

## 2026-10-04 faktai prieš aktyvų API testą

- Naudotojas patvirtino, kad aplikacija veikia `https://rinkissaupigiausia.online`. Projekto konfigūracijoje produkcinis API yra `https://aboutyou-private-catalog-api.aurimas-zvirb.workers.dev`; jo `/health` 15:27 UTC grąžino HTTP 200 ir VPS Supabase backend adresą.
- Agentui neprieinama prisijungusi naršyklės sesija (`iab` ir `chrome` paviršiai nepasiekiami). Joks autentifikuotas facetų API benchmark kvietimas dar nebuvo išsiųstas; žetono neprašyta ir jis niekur neįrašytas.
- Manifestas sugeneruotas iš katalogo `completed_version = 2051`, kai `requested_version = 2054`. Po sėkmingo refresh jį reikia sugeneruoti iš naujo prieš matavimą.
- Matavimo įrankio saugiklis buvo paleistas be autentifikavimo žetono ir be HTTP facetų užklausų: jis teisingai sustojo, nes 15:57 UTC jau buvo `completed_version = 2051`, `requested_version = 2055`. Jokio rezultatų JSONL failo ar cache įrašo šis bandymas nesukūrė.
- Skaitymo režimu `catalog_read_model_refresh_state` parodė pakartotinius `57014: canceling statement due to statement timeout` po maždaug **300 s**: ciklai, prasidėję 15:30, 15:35, 15:40, 15:45 ir 15:50 UTC, baigėsi nesėkmingai. Po 15:50 ciklo `requested_version = 2054`, `completed_version = 2051`, `last_duration_ms = 300243`.
- Paskutinė 16:01 UTC patikra: 15:55 ciklas taip pat baigėsi po **300 311 ms** su `57014`; `requested_version = 2055`, `completed_version = 2051`. Tai jau šeši iš eilės matyti nesėkmingi 5 min. ciklai.
- 15:47–15:49 UTC vykstančio ciklo `pg_locks` rodė užraktą naujajam `catalog_effective_size_membership_read` ir jau paliestus tris ankstesnius materializuotus vaizdus. Iki 15:49 UTC nebuvo `catalog_static_size_facets_cache` rašymo užrakto. Tai rodo, kad naujojo effective narystės modelio atnaujinimas yra kritinė šio ciklo dalis; tikslus jo ir visos grandinės laikas atskirai dar neišmatuotas.
- `codex_reader` neturi prieigos prie `cron` ir `extensions` schemų, todėl iš šios sesijos neprieinami cron istorijos ir `pg_stat_statements` įrašai. Nėra pagrindo vien iš dabartinių duomenų teigti, kad tai vienintelė laiko limito priežastis.
- Atskirai pastebėta dydžių rakto korektiškumo problema: materializuotas modelis turi `shirts:-l` su etikete `XL` (15 405 eilutės) ir `clothing:--l` su etikete `XXL` (13 091 eilutė). Dabartinė `catalog_size_value_key()` išraiška `×` ir raidę `x` keičia į `-`, todėl šie raktai nėra žmogui aiškūs. Tai nepakeičia šio API matavimo blokavimo priežasties, bet turi būti įtraukta į atskirą dydžių normalizavimo regresiją.

## 16:09 UTC papildoma cron diagnostika

- Naudotojo pateiktame `pg_stat_statements` rezultate pradinė `CREATE MATERIALIZED VIEW public.catalog_effective_size_membership_read` užklausa turėjo vieną vykdymą per **6 429,2 ms**. Kitos matomos brangiausios užklausos buvo pavyzdžių sutikrinimas (**20 911,8 ms**) ir jau žinomi `EXPLAIN` bei scenarijų generatoriaus skaitymai. Šiame išraše nėra atskiro `REFRESH MATERIALIZED VIEW` vykdymo, todėl 6,4 s **nėra** periodinio atnaujinimo trukmės įrodymas. Nutrauktos ar funkcijos viduje vykdomos komandos gali nepatekti į šią statistiką; tiksliai priežasčiai reikia cron vykdymų istorijos ir vykdymo fazių laiko.
- 16:09:21 UTC skaitymo režimo patikroje `requested_version = 2056`, `completed_version = 2051`, paskutinė klaida `57014: canceling statement due to statement timeout`, `last_duration_ms = 300214`. Naujas procesas turėjo `catalog_effective_size_membership_read` užraktą. `codex_reader` nemato to proceso pilnos `pg_stat_activity.query` dėl teisių. Cron užduoties eilutės ir `cron.job_run_details` rezultatų naudotojas dar nepateikė.
- Serverio `pg_stat_statements.track` reikšmė yra `top`. Tai paaiškina, kodėl PL/pgSQL funkcijos viduje vykdomas `REFRESH MATERIALIZED VIEW` nepatenka į šios statistikos išrašą; jo trukmės iš pateiktos lentelės apskaičiuoti negalima.
- Naudotojui dar kartą grįžo tik `pg_stat_statements` lentelė. Diagnostikos SQL pakeistas į vieną rezultatų lentelę su `cron_job`, `recent_runs` ir `statement_samples` skyriais, kad SQL Editor parodytų ir pirmąsias dvi dalis. 16:14:36 UTC būklė išliko nesėkminga: `requested_version = 2056`, `completed_version = 2051`; 16:05 pradėtas ciklas baigėsi 16:10 po **300 236 ms** su `57014`.

## Būsena ir tęsinys

**API benchmark nepradėtas.** Prieš jį reikia pašalinti arba atskirai įvertinti katalogo refresh 300 s timeout, pasiekti `requested_version = completed_version`, atnaujinti scenarijų manifestą pagal tą versiją ir turėti prisijungusią aplikacijos sesiją. Po to bandomoji serija ir pilnas matavimas bus išsaugoti atskiruose datos bei laiko žymą turinčiuose JSONL failuose. Užklausų cache įrašai nebus trinami vien dėl matavimo.
