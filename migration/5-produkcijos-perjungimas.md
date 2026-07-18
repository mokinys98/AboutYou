# 5 fazė — produkcinis cutover

## Progreso varnelės — atnaujinti pirmiausia

- [x] Visi 4 fazės STOP vartai uždaryti arba aiškiai priimti atsakingo operatoriaus.
- [x] `npm run migration:preflight` rehearsal režimu prieš freeze grąžina visus PASS.
- [x] Sukurtas šviežias automatinis R2 backup ir pilnas disposable restore patikrintas (`RTO 53 s`).
- [x] Sustabdyti production Worker cron triggeriai ir patikrinta, kad nėra vykstančių rašančių GitHub workflow.
- [ ] Užfiksuotas finalus source/target skirtumas ir pasirinktas authoritative target.
- [x] GitHub production secrets perjungti į VPS Supabase per `production-vps` environment.
- [x] Production Worker server-only secrets perjungti į VPS Supabase ir Worker deploy’intas.
- [x] Production Pages public Supabase URL/anon key perjungti į VPS ir atliktas rebuild.
- [x] `MIGRATION_PHASE=cutover npm run migration:preflight` grąžina `18/18 PASS`.
- [ ] Atlikti login, logout, katalogo, filtrų, product detail, watchlist ir admin write smoke testai.
- [x] Worker cron triggeriai vėl įjungti po automatinių cutover vartų PASS.
- [x] Užfiksuotas cutover laikas `2026-07-18 22:49 UTC` ir pradėtas 24 val. stabilizavimo langas.
- [x] Neesminiai vartai — išorinis alert delivery, sena diagnostinių Storage objektų istorija, Telegram ir pilnas invite/PKCE testas — priimti kaip post-cutover darbai.
- [x] Aktyvuotas atskiras GitHub `production-vps` environment kelias, paliekant esamus repo secrets source rollback’ui.

**Būsena:** vykdomas cutover. Pages ir Worker naudoja VPS, cron’ai atkurti, metadata
`50/50` canary sėkmingas, o pilnas katalogo sync paleistas. Iki 5 fazės uždarymo liko
rankinis production UI smoke ir finalaus source/target sprendimo užfiksavimas.

**Cutover būsena 2026-07-19:** production Pages runtime config ir production Worker
`/health.backendOrigin` rodo VPS Supabase; cutover preflight baigėsi `18/18 PASS`.
Production Worker versija `362b8026-9728-43b2-8c47-0cdcc6cfb4ff` turi visus tris cron’us.
GitHub metadata canary run `29664134768` atnaujino 50/50 produktų be retry ar schema klaidų.

Trumpas operatoriaus sąrašas: [Production VPS taskeris](5a-production-vps-taskeris.md).

## Nekeičiamos saugumo ribos

- `SUPABASE_SERVICE_ROLE_KEY` lieka tik Worker ir GitHub server-side secret saugyklose.
- Pages gauna tik VPS URL ir viešą anon raktą.
- Source Supabase cutover metu netrinamas ir nekeičiamas; jis paliekamas rollback-only.
- VPS Postgres, Supavisor, Kong ir Studio portai viešai neatidaromi.
- Telegram vieno boto webhook perjungimas vykdomas atskirai; antro boto nekuriame.

## Reikšmių žurnalas

Prieš keitimą password manager’yje užpildyti realias reikšmes. Į Git jų nerašyti.

| Vieta | Parametras | Rollback reikšmė | Nauja reikšmė | Patikra |
|---|---|---|---|---|
| GitHub Actions `production-vps` environment | `SUPABASE_URL` | workflow eilutę grąžinti į repo source secrets | VPS canonical URL | workflow preflight |
| GitHub Actions `production-vps` environment | `SUPABASE_SERVICE_ROLE_KEY` | workflow eilutę grąžinti į repo source secrets | VPS raktas | ribotas canary |
| Worker secret | `SUPABASE_URL` | source URL | VPS canonical URL | `/health`, JWKS |
| Worker secret | `SUPABASE_SERVICE_ROLE_KEY` | source raktas | VPS raktas | autorizuotas katalogas |
| Pages env | `NUXT_PUBLIC_SUPABASE_URL` | source URL | VPS canonical URL | runtime config |
| Pages env | `NUXT_PUBLIC_SUPABASE_ANON_KEY` | source anon | VPS anon | login |
| Pages env | `NUXT_PUBLIC_API_BASE` | production Worker | production Worker | runtime config |

## T-30 min. — preflight ir freeze

Repo šaknyje:

```powershell
npm.cmd run migration:preflight
```

VPS:

```bash
sudo systemctl start aboutyou-supabase-backup.service
sudo systemctl --no-pager --full status aboutyou-supabase-backup.service
sudo systemctl start aboutyou-vps-monitor.service
sudo journalctl -u aboutyou-vps-monitor.service -n 100 --no-pager
```

Toliau Cloudflare Dashboard laikinai pašalinti / išjungti visus tris production Worker
cron triggerius ir ekrano kopijoje užfiksuoti jų reikšmes:

- `17 */6 * * *` — catalog workflow;
- `47 * * * *` — metadata workflow;
- `*/5 * * * *` — Telegram outbox.

GitHub Actions patikrinti, kad `Sync catalog` ir `Sync product metadata` nebeturi
`queued` ar `in_progress` run. Freeze metu rankinių sync workflow neleisti.

## T-15 min. — finalus duomenų sprendimas

VPS užfiksuoti target checkpoint:

```bash
sudo docker exec supabase-db psql -P pager=off -U postgres -d postgres -c \
"SELECT count(*) AS products FROM public.products;
 SELECT count(*) AS categories FROM public.categories;
 SELECT requested_version,completed_version,last_status,last_error
 FROM public.catalog_read_model_refresh_state;"
```

Jei source po paskutinio target sync dar turi naujesnių reikalingų įrašų, cutover stabdyti
ir atlikti suplanuotą delta sync. Negalima vienu metu palikti source ir VPS kaip aktyvių
writer’ių.

## T-10 min. — secrets ir deploy

Esamų GitHub repository secrets nekeisti — jie paliekami source rollback’ui. VPS
reikšmes įrašyti į atskirą `production-vps` environment; abu rinkimo workflow jau
paruošti naudoti šį environment:

```powershell
gh secret set SUPABASE_URL --env production-vps
gh secret set SUPABASE_SERVICE_ROLE_KEY --env production-vps
```

Worker kataloge pakeisti abu production secrets interaktyviai ir deploy’inti tą patį
patikrintą kodą:

```powershell
cd apps/api
npx.cmd wrangler secret put SUPABASE_URL
npx.cmd wrangler secret put SUPABASE_SERVICE_ROLE_KEY
npx.cmd wrangler deploy
cd ../..
```

Cloudflare Pages production Variables and secrets pakeisti VPS public reikšmėmis ir
paleisti naują production deployment. `NUXT_PUBLIC_SUPABASE_ANON_KEY` nėra service-role
raktas.

## T+0 — automatinis ir rankinis smoke

```powershell
$env:MIGRATION_PHASE="cutover"
npm.cmd run migration:preflight
Remove-Item Env:MIGRATION_PHASE
```

Cutover režimas papildomai privalomai tikrina, kad ne tik Production Pages, bet ir
Production Worker `/health.backendOrigin` rodo į VPS Supabase. Tai apsaugo nuo dalinio
perjungimo, kai naršyklė jau naudoja VPS, tačiau server-side Worker dar rašo į source.

Rankiniu būdu vienoje naujoje private/incognito sesijoje patikrinti:

1. invite-only vartotojo password login;
2. katalogą, bent du filtrus ir pagination;
3. produkto puslapį ir kainų istoriją;
4. watchlist add/remove;
5. admin dashboard ir vieną grįžtamą write operaciją;
6. logout ir prieigos praradimą po logout;
7. VPS monitorių bei Worker logus be naujų 5xx.

## GO ir scheduler’ių atnaujinimas

Tik jei automatinis preflight ir visi rankiniai smoke testai sėkmingi:

1. atkurti tris production Worker cron triggerius;
2. paleisti vieną ribotą production catalog workflow;
3. patikrinti `sync_runs` ir read-model refresh;
4. pereiti į [6 fazę](6-stabilizavimas.md).

## Rollback

Rollback pradėti nedelsiant, jei login neveikia, katalogas masiškai grąžina 5xx,
atsiranda duomenų korupcijos požymių arba per 15 min. nepavyksta nustatyti priežasties.

1. vėl sustabdyti Worker cron triggerius;
2. Pages grąžinti source URL/anon ir redeploy’inti;
3. Worker grąžinti source URL/service-role ir redeploy’inti;
4. GitHub workflow pašalinti `environment: production-vps`, kad jie vėl naudotų nepakeistus repo source secrets, bet workflow dar nejungti;
5. paleisti rehearsal preflight ir rankinį source smoke;
6. tik po source GO atkurti scheduler’ius;
7. VPS palikti incidento analizei, netrinti DB ar logų.

Rollback nekeičia po cutover į VPS jau įrašytų duomenų atgal į source automatiškai.
Jei VPS gavo unikalių write operacijų, prieš ilgesnį source naudojimą būtinas atskiras
duomenų suderinimo sprendimas.
