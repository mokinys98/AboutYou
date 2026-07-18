# 4 fazė — Pages, Worker ir produkcinio perjungimo rehearsal

## Progreso varnelės — atnaujinti pirmiausia

- [x] VPS Supabase pasiekiamas per canonical staging HTTPS hostname.
- [x] Katalogo ir metadata GitHub Actions staging workflow naudoja VPS Supabase.
- [x] VPS `pg_cron` read-model refresh ir istorijos cleanup darbai aktyvūs be dublikatų.
- [x] Metadata canary: 50/50 `complete`, vienas `success_sample/ready`, fizinis `sync-raw` objektas, refresh `38/38`.
- [x] Patikrintas naujo raw payload nuskaitymas, ne tik Storage metaduomenys (2026-07-18: `11 528` B, `gzip -t` praėjo).
- [x] Pakartotas DB/WAL checkpoint po metadata canary (DB `797 MB`, `pg_wal` `608 MiB`, 2026-07-18).
- [x] VPS `/srv/supabase/docker/.env` sourcing patikrintas be `command not found` perspėjimų (2026-07-18).
- [x] Paruošta atskira Cloudflare Worker staging konfigūracija (`aboutyou-private-catalog-api-staging`) be cron’ų; `wrangler deploy --dry-run --env staging` praėjo.
- [x] Staging Worker deploy’intas su VPS Supabase secrets; `/health` grąžina `{"ok":true}` (2026-07-18).
- [x] Staging Worker pasiekia VPS JWKS (`200`), o neautorizuotas `/v1/catalog` grąžina `401` (2026-07-18).
- [x] Staging Worker CORS leidžia Preview origin; OPTIONS patikra iš Preview grąžina `204` (2026-07-18).
- [x] Worker staging aplinkoje patikrinti JWKS/issuer, `/health`, katalogą, filtrus ir watchlist; admin endpoint’ai dar nepatikrinti.
- [x] Per staging Worker atliktas invite-only vartotojo JWT smoke testas: prisijungimas, katalogas, filtrai, produkto peržiūra ir watchlist veikia (2026-07-18).
- [x] Atkurti source `brand_tiers` įrašai be senų Auth vartotojų priklausomybės: `106` įrašai, `updated_by = NULL` (2026-07-18).
- [ ] TODO po migracijos: palikti atkurtus `brand_tiers` kaip globalius default’us ir suprojektuoti vartotojo individualius tier override’us (atskira lentelė/RLS/API), kad vartotojas galėtų prisitaikyti filtravimą sau nepakeisdamas globalių reikšmių.
- [ ] VPS Auth patikrinti invite, password login, PKCE callback, logout ir priverstinį re-login; savitarnos recovery netaikomas.
- [ ] VPS Auth/SMTP ir redirect allow-list patikrinti su galutiniu Pages hostname.
- [x] Cloudflare Pages preview build naudoja VPS `NUXT_PUBLIC_SUPABASE_URL`, VPS anon raktą ir staging Worker API URL.
- [x] Pages preview atliktas katalogo, filtrų, produkto ir watchlist smoke testas; Production nepakeistas (2026-07-18).
- [x] Automatizuotas viešas rehearsal preflight sustiprintas Worker backend origin patikra; po staging Worker deploy pakartotinai `17/17` PASS (2026-07-19).
- [x] VPS paleistas `scripts/migration/vps-readiness.sh`: host, SSH, UFW, Docker, Tunnel, konteineriai, portai, JWKS, Postgres, cron ir R2 secret teisės tvarkingi; nustatytas vienas realus trūkumas — nėra backup systemd timerio (2026-07-18).
- [x] Paruoštas vieno paleidimo `scripts/migration/install-vps-backup.sh` diegiklis: custom-format DB dump, roles be slaptažodžių, fiziniai Storage baitai, Postgres custom/pgsodium raktų volume, `age` šifravimas, R2 upload dydžio patikra, vietinė 3 d. retencija ir kasdienis systemd timeris.
- [x] VPS įdiegtas ir aktyvuotas kasdienis `aboutyou-supabase-backup.timer`.
- [x] Pirmas automatinio kelio backup sėkmingas: R2 objektas `50 731 288` B, lokali šifruota kopija, SHA-256 ir service `0/SUCCESS` patvirtinti (2026-07-18).
- [x] Paruoštas `scripts/migration/verify-vps-backup-restore.sh`: naujausias R2 backup atkuriamas izoliuotame konteineryje be tinklo/portų, neliečiant staging DB.
- [x] Įdiegti `scripts/migration/vps-monitor.sh` ir `install-vps-monitoring.sh`: 5 min. systemd timeris aktyvus, pirmas paleidimas `0/SUCCESS`, visos vidinės patikros `PASS` (2026-07-19).
- [ ] Patikrinta Telegram webhook, profilio susiejimas ir bent vienas testinis alertas per Worker → VPS DB.
- [x] Telegram staging rehearsal sąmoningai atidėtas: antro boto nekuriame, production botas lieka nepaliestas iki galutinio cutover.
- [ ] TODO po migracijos: pridėti aiškią profilio Telegram atjungimo UI logiką ir parengti vieno production boto webhook perjungimo į VPS Worker procedūrą su rollback.
- [ ] Priimtas sprendimas dėl istorinių `sync-raw` / `sync-debug` objektų: perkelti su parity arba formaliai atsisakyti istorijos.
- [x] Įrodytas automatinis šifruotas VPS backup į R2 ir restore į disposable aplinką: pilnas restore bei smoke testas sėkmingas, RTO `53 s` (2026-07-19).
- [x] Veikia periodinės disk, Docker health, backup age, JWKS/API health ir refresh/cron failure patikros.
- [ ] Patikrintas išorinio webhook gedimo ir atsistatymo pranešimų pristatymas.
- [ ] Patvirtintas produkcinio masto/SLO kriterijus: pilnas faktinio katalogo testas arba formaliai priimta mažesnė riba.
- [x] Paruoštas production secret change, freeze, smoke test ir rollback runbook 5 fazės dokumente.

**Būsena:** nepradėtas produkcinis perjungimas. VPS duomenų, rinktuvų, staging Worker
ir Pages Preview kelias veikia, o automatinis off-host backup, izoliuotas restore bei
kas 5 min. vykdomos vidinės monitoringo patikros patvirtinti. Produkcinis Worker ir
Pages dar neturi būti perjungiami, kol neuždaryti likę Auth, išorinio alert pristatymo,
Storage istorijos ir source–target cutover/rollback vartai.

## Automatizuotas viešas preflight

Repo šaknyje paleidžiama:

```powershell
npm.cmd run migration:preflight
```

Staging Worker `/health` grąžina tik neslaptą `backendOrigin`, todėl preflight ne tikrina
vien bendro Worker gyvybingumo, bet ir įrodo, kad jo server-side `SUPABASE_URL` rodo į
VPS. Service-role raktas atsakyme negrąžinamas. 2026-07-19 staging Worker versija
`0fe9f030-d52d-4930-b7d1-e7ba978eae07` grąžino VPS origin, o visas rehearsal baigėsi
`17/17 PASS`. Rehearsal metu senesnis production Worker dar gali neturėti šio lauko;
cutover režimu production backend origin patikra yra privaloma.

Numatytasis `rehearsal` režimas patikrina, kad Preview naudoja VPS Supabase ir staging
Worker, o Production vis dar naudoja source Supabase ir production Worker. Taip pat
tikrinami abiejų Worker `/health`, neautorizuoto katalogo `401`, tikslūs CORS origin ir
abiejų Supabase JWKS. Anon rakto reikšmė neišvedama — tik patvirtinama, kad ji yra.

Galutinio cutover patikrai naudojamas:

```powershell
$env:MIGRATION_PHASE="cutover"
npm.cmd run migration:preflight
Remove-Item Env:MIGRATION_PHASE
```

`cutover` režimas reikalauja, kad Production Pages jau naudotų VPS Supabase, tačiau
vis tiek naudotų production Worker hostname.

## VPS readiness ir automatinis backup

Read-only VPS auditas paleidžiamas taip:

```bash
sudo bash scripts/migration/vps-readiness.sh
```

2026-07-18 auditas parodė pakankamą RAM, swap ir disko rezervą, aktyvius UFW bei
cloudflared, sveikus visus 11 Supabase konteinerių, tik loopback publikuojamus Kong ir
Studio portus, pasiekiamą JWKS, veikiančią DB bei du aktyvius refresh cron darbus.
Refresh būsena buvo `42|42|clean`; tai yra sveika būsena, nes versijos sutampa ir nėra
neįvykdytos refresh užklausos. Audito tikrinimas pataisytas priimti tiek `clean`, tiek
`refreshed`, kai versijos sutampa ir `last_error` tuščias.

Vienintelis realus audito trūkumas — automatinio backup systemd unit nebuvimas.
Paruoštas diegiklis:

```bash
sudo bash scripts/migration/install-vps-backup.sh
```

Diegiklis prašo tik viešo `age1...` gavėjo rakto. Privatus age identity į backup
serverį nekopijuojamas. Backup apima ne tik loginį Postgres dump, bet ir fizinius
Supabase Storage objektų baitus bei `/etc/postgresql-custom` turinį, kuriame saugoma
atkūrimui svarbi Postgres custom/pgsodium raktų medžiaga. Storage konteineris šių
duomenų kopijavimo metu trumpam pristabdomas ir visada atnaujinamas per cleanup trap.
Pirmas backup laikomas patvirtintu tik tada, kai service baigiasi sėkmingai, R2 objekto
dydis sutampa su lokaliu šifruotu failu ir užfiksuojamas SHA-256.

2026-07-18 pirmas paleidimas sėkmingai sukūrė roles ir custom-format DB dump,
suarchyvavo fizinius Storage baitus bei Postgres custom/pgsodium medžiagą ir užšifravo
archyvą su `age`. Įkėlimas į R2 nepavyko su `HTTP 501 NotImplemented`. Bendrinis
`rclone` S3 provideris `Other` buvo pakeistas į oficialų Cloudflare R2 profilį
(`provider=Cloudflare`, `region=auto`, `acl=private`, `no_check_bucket=true`), tačiau
2022 m. Ubuntu `rclone 1.60.1-DEV` paketas grąžino tą patį `501`. Prieš kitą bandymą
VPS atnaujintas į oficialų `rclone 1.74.4`; diegiklis nuo šiol atmeta senesnes nei
`1.70.0` versijas, kad nepradėtų brangaus dump su žinomu nesuderinamu klientu.

Po atnaujinimo pakartotinis bandymas baigtas sėkmingai: service grąžino `0/SUCCESS`,
R2 objektas ir vietinė `age` kopija yra `50 731 288` B, užfiksuotas SHA-256
`67b2c4abca82954dc70851836b208c972ec9610172a49abf6b08a8191cc1243a`, o nuotolinis
kelias yra `automatic/20260718T211516Z/aboutyou-supabase-20260718T211516Z.tar.age`.
Automatinio backup sukūrimo ir off-host upload vartas uždarytas; likęs atskiras vartas —
šio formato restore į disposable aplinką ir faktinio RTO užfiksavimas.

Pirmas disposable restore bandymas sėkmingai parsisiuntė naujausią objektą iš R2,
iššifravo jį ir patvirtino `roles.sql`, `database.dump`, `storage-files.tar`,
`postgresql-custom.tar` bei `metadata.txt` checksum. Izoliuoto Postgres inicializacija
sustojo prieš importą, nes iš veikiančio konteinerio `Cmd` buvo perimtas tuščias `""`
argumentas. Staging DB nepaliesta, cleanup pašalino disposable konteinerį; scenarijus
pataisytas atmesti tuščius argumentus. Restore vartas lieka atviras iki pakartojimo.

Pakartojus su pataisyta versija disposable Postgres sėkmingai startavo, tačiau role
settings importas sustojo, nes Supabase image `postgres` rolė nėra superuser ir negali
keisti reserved `anon`. Scenarijus pataisytas aptikti tikrą disposable konteinerio
superuser (prioritetas `supabase_admin`) ir roles nustatymus taikyti jo vardu.

Kitas bandymas superuser vardu pritaikė esamų roles nustatymus, bet aptiko, kad švari
image inicializacija neturi backup esančios `supabase_privileged_role`. Restore
scenarijus papildytas idempotentiškai sukurti tik trūkstamas roles iš dump `CREATE ROLE`
eilučių, tada taikyti `ALTER ROLE` ir `GRANT`; DB dump taip pat atkuriamas superuser
vardu, nes jame yra extensions ir kiti privilegijuoti Supabase objektai.

Dar vienas bandymas parodė, kad `supabase_functions_admin` dump faile neturi atskiros
`CREATE ROLE` eilutės. Pirmoji pataisa surinko roles iš `CREATE ROLE` ir `ALTER ROLE`,
tačiau pakartotinis bandymas patvirtino, kad nepakanka ir šių dviejų komandų tipų:
rolė gali būti minima tik narystės `GRANT` komandoje. Restore scenarijus išplėstas
surinkti suteikiamą bei gaunančią roles ir iš `GRANT`, pašalinti pasikartojimus ir
prieš settings importą idempotentiškai sukurti visas trūkstamas roles disposable
konteineryje.

SHA-256 patvirtintas pakartojimas įrodė, kad VPS vykdė naują scenarijų, tačiau
`supabase_privileged_role` vis tiek nebuvo aptikta: dump naudoja ir necituotą SQL
identifikatoriaus formą. Regex parseris pakeistas tokenų parseriu, palaikančiu tiek
`"role"`, tiek `role` formas `CREATE ROLE`, `ALTER ROLE` ir paprastoje narystės
`GRANT role TO role` komandoje. Prieš settings importą dabar papildomai tikrinama,
kad kiekviena surinkta rolė iš tikrųjų egzistuoja disposable Postgres konteineryje.

Pakartojus su tokenų parseriu scenarijus sustojo dar prieš roles apdorojimą su
`the database system is shutting down`. Priežastis – `pg_isready` aptiko laikiną
Postgres procesą, kurį image entrypoint naudoja inicializacijos skriptams, o šis
vėliau pagal numatytą seką išjungiamas prieš galutinį serverio startą. Starto laukimas
pataisytas atskirti laikiną inicializacijos serverį nuo galutinio serverio starto.

Pirmas bandymas šį perėjimą aptikti pagal konteinerio PID 1 nepavyko: Supabase image
PID 1 išlaiko entrypoint procesą. Tačiau pilnas konteinerio logas patvirtino stabilų
`PostgreSQL init process complete; ready for start up.` žymeklį. Jis taip pat parodė,
kad image migracija `20260211120934_supabase_privileged_role.sql` pati sukuria
`supabase_privileged_role`, todėl ankstesni role importo gedimai buvo tos pačios
per ankstyvos jungties prie laikino serverio pasekmė. Scenarijus dabar laukia šio
patvirtinto inicializacijos žymeklio ir tik tada vykdo galutinį `pg_isready`.

2026-07-19 galutinis pakartojimas baigtas `RESTORE_VERIFY_SUCCESS`. Naujausias
automatinis `age` backup buvo paimtas tiesiai iš R2, iššifruotas ir patikrintas pagal
visų payload dalių SHA-256. Izoliuotame, tinklo ir host portų neturinčiame disposable
Postgres atkurti roles, custom-format DB dump, fiziniai Storage baitai ir Postgres
custom/pgsodium medžiaga. Smoke rezultatai: `products=53704`, `categories=190`,
`auth_users=1`, `storage_objects=1`, DB dydis `689032339` B, Storage `11528` B.
Išmatuotas bendras RTO `53 s`; naudotas R2 objektas
`automatic/20260718T211516Z/aboutyou-supabase-20260718T211516Z.tar.age`. Staging DB
nebuvo liečiama, o disposable konteinerį ir laikinas iššifruotas kopijas pašalino trap.

## VPS periodinis monitoringas

Paruoštas diegiklis įrašo read-only monitorių į `/usr/local/sbin`, sukuria kas 5 min.
systemd timerį ir pirmą patikrą paleidžia iškart. Monitorius tikrina:

- root disko ribą;
- `docker` ir `cloudflared` servisus bei 11 Supabase konteinerių;
- viešą Supabase JWKS ir Worker `/health` atsakymą;
- backup timerį, paskutinio service rezultatą ir lokalaus šifruoto backup amžių;
- read-model versijų lygybę, klaidos nebuvimą, cron skaičių ir 30 min. nesėkmes.

2026-07-19 diegimas ir pirmas paleidimas sėkmingi: service baigėsi
`0/SUCCESS`, backup amžius buvo `3811 s`, refresh būsena `42/42 clean`, abu cron
darbai aktyvūs, o per paskutines 30 min. refresh klaidų nerasta. `inactive (dead)` po
paleidimo yra normali oneshot service būsena; kitą paleidimą valdo aktyvus timeris.

Diegimas VPS, parsisiuntus abu failus iš to paties immutable commit į `/tmp`:

```bash
sudo bash /tmp/install-vps-monitoring.sh
```

Be išorinio webhook gedimai matomi `systemctl --failed` ir journal. Pasirinktinai
`/etc/aboutyou-monitor/monitor.env` faile su `0600` teisėmis galima nustatyti
kabutėmis apsaugotą `ALERT_WEBHOOK_URL`; pranešimas siunčiamas tik pereinant iš healthy
į failed ir atskiras pranešimas – grįžus į healthy. Production cutover metu tame pačiame
faile staging health URL pakeičiami production URL.

## Galutinė architektūra

Cloudflare Pages ir Worker lieka Cloudflare platformoje. Į VPS keliasi tik Supabase
paslaugos ir vidiniai Postgres darbai:

```text
Naršyklė / Cloudflare Pages
  ├─ Supabase Auth ir browser client ──> Cloudflare Tunnel ──> VPS Supabase
  └─ /v1 aplikacijos API ──────────────> Cloudflare Worker ──> VPS Supabase

Cloudflare Worker cron
  ├─ katalogo grafikas ────────────────> GitHub Actions catalog workflow
  ├─ metadata grafikas ────────────────> GitHub Actions metadata workflow
  └─ kas 5 min. ───────────────────────> Telegram outbox per VPS Supabase

VPS pg_cron
  ├─ kas 5 min. ───────────────────────> read-model refresh
  └─ kasdien 03:15 ────────────────────> pg_cron istorijos cleanup
```

Katalogo ir metadata Chromium rinktuvas nėra perkeliamas į VPS cron. Jį toliau
vykdo GitHub Actions, o Cloudflare Worker lieka produkcinių workflow dispatch šaltiniu.
Taip išvengiama dvigubų writer’ių.

## Keičiamos konfigūracijos

| Vieta | Parametras | Rehearsal / production reikšmė |
|---|---|---|
| Pages build env | `NUXT_PUBLIC_SUPABASE_URL` | VPS canonical HTTPS URL |
| Pages build env | `NUXT_PUBLIC_SUPABASE_ANON_KEY` | VPS viešas anon raktas |
| Pages build env | `NUXT_PUBLIC_API_BASE` | staging arba production Worker URL |
| Worker secret | `SUPABASE_URL` | VPS canonical HTTPS URL |
| Worker secret | `SUPABASE_SERVICE_ROLE_KEY` | VPS server-only service-role raktas |
| GitHub Environment / repo secret | `SUPABASE_URL` | VPS canonical HTTPS URL |
| GitHub Environment / repo secret | `SUPABASE_SERVICE_ROLE_KEY` | VPS server-only service-role raktas |

`SUPABASE_SERVICE_ROLE_KEY` negali patekti į Pages build env, Nuxt bundle, Git ar
dokumentaciją. Jei Pages hostname nesikeičia, Worker `ALLOWED_ORIGIN` ir `WEB_APP_URL`
lieka `https://aboutyou-private-catalog-web.pages.dev`.

## Rehearsal seka

1. Užbaigti raw read ir post-canary DB/WAL patikrą.
2. Paruošti izoliuotą Worker staging aplinką. Dabartinis `apps/api/wrangler.jsonc`
   turi tik pagrindinę Worker konfigūraciją, todėl produkcinio Worker secret’ų naudoti
   staging bandymui negalima.
3. Staging Worker nustatyti VPS `SUPABASE_URL` ir service-role secret, išlaikant
   server-only ribą.
4. Gauti naują VPS Auth JWT ir patikrinti Worker JWKS/issuer bei autorizuotus `/v1`
   endpoint’us.
5. Sukurti Pages preview build su VPS public URL/anon key ir staging Worker API URL.
6. Atlikti invite-only Auth, katalogo, filtrų, product detail, watchlist, admin ir
   Telegram smoke testus.
7. Backup/restore ir vidinis monitoringas įrodyti; patikrinti išorinį alert pristatymą ir priimti Storage istorijos bei
   masto/SLO sprendimus.
8. Parengti production perjungimo lentelę: senos reikšmės rollback’ui, naujos
   reikšmės, savininkas, keitimo trukmė ir patikros komanda.

### Raw payload checkpoint — 2026-07-18

Per staging Supabase authenticated Storage endpoint nuskaitytas naujas objektas
`sync-raw/samples/v5/0026d521-3471-488e-9747-3e82132e3ca8/5c44cb7fce6564c005ec431a297cb6d4496e24427c4a3f5a96868ffd1c034ed5.json.gz`.
Failas gautas su `SERVICE_ROLE_KEY`, jo dydis buvo `11 528` baitai ir `gzip -t`
patikra praėjo. Tai patvirtina fizinį objekto turinio nuskaitymą, ne tik
`storage.objects` metaduomenų įrašą. Raktas ar jo reikšmė dokumentacijoje
nenurodomi.

Bandymas taip pat parodė, kad `/srv/supabase/docker/.env` nėra saugiai
interpretuojamas kaip shell failas: sourcing išvedė `Organization: command not found`
ir `Project: command not found`. Tai nepaveikė šio objekto nuskaitymo, bet prieš
backup/restore ar kitą automatizaciją reikia normalizuoti tas eilutes.

## Production cutover taisyklė

Per cutover laikinai sustabdomas Cloudflare Worker cron dispatch ir palaukiama, kol
baigsis visi rašantys GitHub workflow. Tada atliekamas final source–target palyginimas
arba patvirtinama, kad VPS jau yra vienintelis aktualus duomenų šaltinis. Tik po to:

1. Worker secrets perjungiami į VPS ir Worker deploy’inamas;
2. GitHub production secrets perjungiami į VPS;
3. Pages public URL/key pakeičiami ir atliekamas rebuild/deploy;
4. vykdomi login, JWKS, `/health`, katalogo, filtrų, admin ir write smoke testai;
5. tik po GO vėl įjungiamas Worker cron dispatch;
6. senas Supabase source paliekamas rollback-only per sutartą stebėjimo langą.

## Stop vartai

Production perjungimas draudžiamas, jei bent viena sąlyga teisinga:

- Worker nevaliduoja VPS JWT per naują JWKS/issuer;
- Pages preview dar naudoja source URL arba seną anon raktą;
- neveikia invite/login/callback/logout;
- neaišku, kuris scheduler’is paleidžia catalog/metadata workflow;
- nėra šviežio automatinio off-host backup ir patikrinto restore;
- nėra patikrinto išorinio monitoring alert pristatymo kritiniams gedimams;
- nepriimtas istorinių Storage objektų parity arba atsisakymo sprendimas;
- nėra rollback reikšmių ir maksimalaus sprendimo laiko.

## Kitas saugus veiksmas

Užbaigti galutinio Pages hostname Auth/SMTP testus, patikrinti išorinio VPS alert
pristatymą ir užbaigti production secret/freeze/smoke/rollback vartus. Produkcinio
Worker ir Pages secret’ų dar nekeisti.

### Post-canary DB/WAL checkpoint — 2026-07-18

Po metadata canary pakartotas matavimas: DB dydis `797 MB`, `pg_wal` katalogas
`608 MiB`. `pg_stat_wal` rodė `17 428 762` WAL records, `4 219 MB` WAL bytes,
`195 881` `wal_buffers_full`, `276 281` `wal_write` ir `79 572` `wal_sync`.
DB dydis nekito, o WAL katalogas sumažėjo nuo ankstesnių `816 MiB`; tai suderinama
su checkpoint ir WAL retencijos veikimu.
