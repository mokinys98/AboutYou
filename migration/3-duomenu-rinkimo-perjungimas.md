# 3 fazÄ— â€” duomenÅ³ rinkimo perjungimas Ä¯ VPS staging

## Progreso blokas

- [x] Staging sync aplinkos kintamieji paruoÅ¡ti atskirai nuo production naudojimo.
- [x] Patikrinta, kad staging `sync_targets` egzistuoja: 25 aktyvÅ«s targetai.
- [ ] Atliktas dry-run / konfigÅ«racijos testas be raÅ¡ymo Ä¯ DB.
- [x] Atliktas canary sync: po 10 produktÅ³ kiekvienam iÅ¡ 25 targetÅ³ (iki 250 produktÅ³ bendrai).
- [x] Patikrinti `sync_runs` ir produktÅ³ pokytÄ¯: 25/25 naujausiÅ³ canary run buvo `success`, kiekvienas po 10 produktÅ³; staging produktÅ³ skaiÄius 51536.
- [x] UÅ¾baigtas read-model refresh: `requested_version=33`, `completed_version=33`, `last_status=refreshed`, `dirty=false`, trukmÄ— 17,1 sek.
- [x] Atliktas antras canary sync su `SYNC_MAX_PRODUCTS=50`: 25/25 targetÅ³ sÄ—kmingi; dauguma surinko 50 produktÅ³, Lacoste 13, treniruoÄiÅ³ targetas 42.
- [x] Po antro canary uÅ¾baigtas ir patikrintas read-model refresh: `requested_version=34`, `completed_version=34`, `last_status=refreshed`, `dirty=false`, trukmÄ— 2,2 sek.
- [x] Sukurtas atskiras rankinis GitHub Actions workflow `.github/workflows/sync-catalog-staging.yml` su `staging` Environment.
- [x] GitHub staging workflow patikrintas: run `29535202751`, 25/25 targetÅ³ sÄ—kmingi, sync trukmÄ— 2 min. 13 sek.
- [x] UÅ¾baigtas po GitHub run papraÅ¡ytÄ… read-model refresh VPS `postgres` sesijoje: `requested_version=35`, `completed_version=35`, `status=clean`.
- [x] Sukurti ir aktyvÅ«s abu VPS `pg_cron` darbai: refresh kas 5 min. ir istorijos cleanup kasdien 03:15.
- [x] GitHub staging workflow ir refresh patikros baigtos; galima svarstyti didesnÄ¯ staging sync.
- [ ] Production sync ir production cron Å¡ioje fazÄ—je nepakeisti.

**BÅ«sena:** PR #1 sujungtas Ä¯ `main`, o GitHub Actions staging canary run `29535202751` baigÄ—si sÄ—kmingai per 3 min. 12 sek. (pats sync â€” 2 min. 13 sek.). Rasti 25 aktyvÅ«s targetai, visi baigÄ—si sÄ—kmingai. VPS sukurti abu reikalingi `pg_cron` darbai, o read-model refresh baigtas `35/35` su `status=clean`. Production nepakeistas.

**Kitas veiksmas:** suplanuoti didesnÄ¯ staging sync paleidimÄ…, bet production workflow secrets ir cron dar nekeisti.

Patikra parodÄ—, kad VPS `cron.job` nÄ—ra nei `catalog-read-model-refresh`, nei jo istorijos
cleanup darbo. Juos reikia idempotentiÅ¡kai sukurti tiesiogiai VPS `postgres` sesijoje;
GitHub workflow pats tik iÅ¡kvieÄia `request_catalog_items_read_refresh()`.

```bash
sudo docker exec supabase-db psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'catalog-read-model-refresh') THEN PERFORM cron.schedule('catalog-read-model-refresh', '*/5 * * * *', 'select public.process_catalog_items_read_refresh();'); END IF; IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'catalog-read-model-refresh-history-cleanup') THEN PERFORM cron.schedule('catalog-read-model-refresh-history-cleanup', '15 3 * * *', 'delete from cron.job_run_details where jobid in (select jobid from cron.job where jobname in (''catalog-read-model-refresh'', ''catalog-read-model-refresh-history-cleanup'')) and end_time < now() - interval ''14 days'';'); END IF; END \$\$;"
sudo docker exec supabase-db psql -At -U postgres -d postgres -c "select jobid,jobname,schedule,active from cron.job where jobname like 'catalog-read-model-refresh%';"
sudo docker exec supabase-db psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select public.process_catalog_items_read_refresh();"
```

```bash
sudo docker exec supabase-db psql -At -U postgres -d postgres -c "select requested_version,completed_version,last_status,last_error from public.catalog_read_model_refresh_state;"
```

TikÄ—tinas rezultatas: `last_status=refreshed` ir `completed_version >= requested_version`. Jei vÄ—l gaunamas timeout, antrÄ… canary kol kas stabdome ir analizuojame refresh trukmÄ™/resursus.

## Tikslas

Naudoti esamÄ… `apps/sync` rinktuvÄ… su Contabo VPS Supabase staging DB, nekeiÄiant production `.env`, GitHub Actions ar production cron.

## Vykdymo modelis

Galutinis rinktuvo vykdytojas yra GitHub Actions (`.github/workflows/sync-catalog.yml` ir
`sync-product-metadata.yml`). VPS nevykdo Chromium rinkimo — jis teikia Supabase API ir
Postgres duomenÅ³ bazÄ™.

Vietiniai canary paleidimai buvo laikina integracinÄ— patikra: jie patvirtino, kad rinktuvas
gali pasiekti staging VPS ir Ä¯raÅ¡yti katalogo duomenis. PrieÅ¡ GitHub paleidimÄ… reikia
atskiro GitHub `staging` Environment su staging reikÅ¡mÄ—mis. Production secrets
(`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`) nekeiÄiami.

Staging workflow sukurtas, sujungtas Ä¯ `main` ir sÄ—kmingai paleistas rankiniu
`workflow_dispatch`. Read-model ir VPS cron patikros baigtos; tik dabar galima planuoti
didesnÄ¯ staging run. Production workflow secrets ir cron dar nepakeisti.

## Staging adresas

```text
https://supabase-staging.rinkissaupigiausia.online
```

Sync procesui reikalingi tik serveriniai kintamieji:

```env
SUPABASE_URL=https://supabase-staging.rinkissaupigiausia.online
SUPABASE_SERVICE_ROLE_KEY=<staging VPS service-role key>
SYNC_MAX_PRODUCTS=10
SYNC_HEADLESS=true
```

`SUPABASE_SERVICE_ROLE_KEY` niekada nekeliamas Ä¯ frontendÄ…, Git ar pokalbÄ¯.

## Saugos vartai

- PrieÅ¡ canary patikrinti, kad `SUPABASE_URL` tikrai yra staging hostname.
- Nenaudoti root `.env` perraÅ¡ymo; kintamuosius nustatyti tik konkretaus proceso sesijoje.
- Pirmam canary naudoti `SYNC_MAX_PRODUCTS=10`.
- Jei targetÅ³ nÄ—ra arba jie neteisingi, sync nestartuoti.
- Jei `sync_runs` gauna `failed`, sustabdyti ir rinkti logus; dydÄ¯ didinti tik po patikros.
