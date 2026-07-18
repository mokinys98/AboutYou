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
- [x] Automatizuotas viešas rehearsal preflight: `npm run migration:preflight` patikrino Pages runtime config, Worker health/CORS/auth gate ir abiejų Supabase JWKS; `16/16` PASS (2026-07-18).
- [x] VPS paleistas `scripts/migration/vps-readiness.sh`: host, SSH, UFW, Docker, Tunnel, konteineriai, portai, JWKS, Postgres, cron ir R2 secret teisės tvarkingi; nustatytas vienas realus trūkumas — nėra backup systemd timerio (2026-07-18).
- [x] Paruoštas vieno paleidimo `scripts/migration/install-vps-backup.sh` diegiklis: custom-format DB dump, roles be slaptažodžių, fiziniai Storage baitai, Postgres custom/pgsodium raktų volume, `age` šifravimas, R2 upload dydžio patikra, vietinė 3 d. retencija ir kasdienis systemd timeris.
- [ ] VPS įdiegti backup timerį, paleisti pirmą backup ir patvirtinti R2 objektą bei service žurnalą.
- [ ] Patikrinta Telegram webhook, profilio susiejimas ir bent vienas testinis alertas per Worker → VPS DB.
- [x] Telegram staging rehearsal sąmoningai atidėtas: antro boto nekuriame, production botas lieka nepaliestas iki galutinio cutover.
- [ ] TODO po migracijos: pridėti aiškią profilio Telegram atjungimo UI logiką ir parengti vieno production boto webhook perjungimo į VPS Worker procedūrą su rollback.
- [ ] Priimtas sprendimas dėl istorinių `sync-raw` / `sync-debug` objektų: perkelti su parity arba formaliai atsisakyti istorijos.
- [ ] Įrodytas automatinis šifruotas VPS backup į R2 ir restore į disposable aplinką su RTO.
- [ ] Veikia disk, Docker health, backup age, API 5xx ir refresh failure alertai.
- [ ] Patvirtintas produkcinio masto/SLO kriterijus: pilnas faktinio katalogo testas arba formaliai priimta mažesnė riba.
- [ ] Paruoštas production secret change, freeze, smoke test ir rollback runbook.

**Būsena:** nepradėtas produkcinis perjungimas. VPS duomenų, rinktuvų, staging Worker
ir Pages Preview kelias veikia. Produkcinis Worker ir Pages dar neturi būti perjungiami,
kol neuždaryti likę Auth, backup/restore, monitoring ir source–target cutover vartai.

## Automatizuotas viešas preflight

Repo šaknyje paleidžiama:

```powershell
npm.cmd run migration:preflight
```

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
7. Įrodyti backup/restore, monitoringą ir priimti Storage istorijos bei masto/SLO
   sprendimus.
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
- nėra monitoring/alertų kritiniams gedimams;
- nepriimtas istorinių Storage objektų parity arba atsisakymo sprendimas;
- nėra rollback reikšmių ir maksimalaus sprendimo laiko.

## Kitas saugus veiksmas

Užbaigus raw read ir post-canary WAL patikrą, paruošti izoliuotą Cloudflare Worker
staging aplinką ir joje išbandyti VPS JWT/JWKS. Produkcinio Worker ir Pages secret’ų
dar nekeisti.

### Post-canary DB/WAL checkpoint — 2026-07-18

Po metadata canary pakartotas matavimas: DB dydis `797 MB`, `pg_wal` katalogas
`608 MiB`. `pg_stat_wal` rodė `17 428 762` WAL records, `4 219 MB` WAL bytes,
`195 881` `wal_buffers_full`, `276 281` `wal_write` ir `79 572` `wal_sync`.
DB dydis nekito, o WAL katalogas sumažėjo nuo ankstesnių `816 MiB`; tai suderinama
su checkpoint ir WAL retencijos veikimu.
