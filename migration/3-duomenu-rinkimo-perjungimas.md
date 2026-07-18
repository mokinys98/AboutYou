# 3A fazė — duomenų rinkimo perjungimas į VPS staging

## Progreso blokas

- [x] Staging sync aplinkos kintamieji paruošti atskirai nuo production naudojimo.
- [x] Patikrinta, kad staging `sync_targets` egzistuoja: 25 aktyvūs targetai.
- [x] Atskiro dry-run režimo rinktuvas neturi; konfigūracija patikrinta mažais staging canary su ribotu rašymu į DB.
- [x] Atliktas canary sync: po 10 produktų kiekvienam iš 25 targetų (iki 250 produktų bendrai).
- [x] Patikrinti `sync_runs` ir produktų pokytį: 25/25 naujausių canary run buvo `success`, kiekvienas po 10 produktų; staging produktų skaičius 51 536.
- [x] Užbaigtas read-model refresh: `requested_version=33`, `completed_version=33`, `last_status=refreshed`, `dirty=false`, trukmė 17,1 sek.
- [x] Atliktas antras canary sync su `SYNC_MAX_PRODUCTS=50`: 25/25 targetų sėkmingi; dauguma surinko 50 produktų, Lacoste 13, treniruočių targetas 42.
- [x] Po antro canary užbaigtas ir patikrintas read-model refresh: `requested_version=34`, `completed_version=34`, `last_status=refreshed`, `dirty=false`, trukmė 2,2 sek.
- [x] Sukurtas atskiras rankinis GitHub Actions workflow `.github/workflows/sync-catalog-staging.yml` su `staging` Environment.
- [x] GitHub staging workflow patikrintas: run `29535202751`, 25/25 targetų sėkmingi, sync trukmė 2 min. 13 sek.
- [x] Užbaigtas po GitHub run paprašytas read-model refresh VPS `postgres` sesijoje: `requested_version=35`, `completed_version=35`, `status=clean`.
- [x] Sukurti ir aktyvūs abu VPS `pg_cron` darbai: refresh kas 5 min. ir istorijos cleanup kasdien 03:15.
- [x] Pridėtas automatinis staging `sync_runs` ir read-model refresh validavimo gate.
- [x] 2026-07-18 atliktas `SYNC_MAX_PRODUCTS=500` testas: 25/25 targetų `success`, apdorotas 10 521 produktas, sync truko 4 min. 26 sek.
- [x] Po 500/target testo read-model refresh baigtas `requested_version=37`, `completed_version=37`, `status=refreshed`, trukmė 24 953 ms.
- [x] Sukurtas atskiras `.github/workflows/sync-product-metadata-staging.yml` workflow.
- [ ] Staging produkto metadata workflow dar nepaleistas; pirmas canary turi naudoti `max_products=50`.
- [x] Production Supabase secrets ir production cron konfigūracija šioje fazėje nepakeisti.
- [x] Po 500/target testo VPS turi 9,1 GiB available RAM ir 174 GiB laisvo disko; swap praktiškai nenaudojamas.
- [ ] Užfiksuoti `sudo docker stats --no-stream`, Postgres DB dydį ir `pg_stat_wal` po apkrovos.

**Būsena:** staging katalogo rinktuvas ir automatinis validavimo gate veikia. Naujausias 500 produktų/target testas apdorojo 10 521 produktą, visi 25 targetai baigėsi sėkmingai, o read-model refresh pasiekė `37/37`. VPS resursų rezervas pagal host metrikas pakankamas, tačiau dar trūksta Docker/Postgres/WAL checkpoint. Staging metadata workflow sukurtas, bet dar nepaleistas. Production konfigūracija nepakeista.

**Kitas veiksmas:** užfiksuoti Docker/Postgres/WAL metrikas ir paleisti tik staging metadata canary su `max_products=50`. Production canary dar nevykdomas.

Istorinis checkpoint: pradžioje VPS `cron.job` neturėjo nei `catalog-read-model-refresh`, nei
istorijos cleanup darbo. Abu darbai vėliau sukurti idempotentiškai ir patikrinti; GitHub
workflow tik iškviečia `request_catalog_items_read_refresh()`, o refresh apdoroja VPS `pg_cron`.

```bash
sudo docker exec supabase-db psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'catalog-read-model-refresh') THEN PERFORM cron.schedule('catalog-read-model-refresh', '*/5 * * * *', 'select public.process_catalog_items_read_refresh();'); END IF; IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'catalog-read-model-refresh-history-cleanup') THEN PERFORM cron.schedule('catalog-read-model-refresh-history-cleanup', '15 3 * * *', 'delete from cron.job_run_details where jobid in (select jobid from cron.job where jobname in (''catalog-read-model-refresh'', ''catalog-read-model-refresh-history-cleanup'')) and end_time < now() - interval ''14 days'';'); END IF; END \$\$;"
sudo docker exec supabase-db psql -At -U postgres -d postgres -c "select jobid,jobname,schedule,active from cron.job where jobname like 'catalog-read-model-refresh%';"
sudo docker exec supabase-db psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select public.process_catalog_items_read_refresh();"
```

```bash
sudo docker exec supabase-db psql -At -U postgres -d postgres -c "select requested_version,completed_version,last_status,last_error from public.catalog_read_model_refresh_state;"
```

Tikėtinas rezultatas: `last_status=refreshed` ir `completed_version >= requested_version`. Jei vėl gaunamas timeout, canary stabdomas ir analizuojama refresh trukmė bei resursai.

## Tikslas

Naudoti esamą `apps/sync` rinktuvą su Contabo VPS Supabase staging DB, nekeičiant production `.env`, GitHub Actions ar production cron.

## Vykdymo modelis

Galutinis rinktuvo vykdytojas yra GitHub Actions (`.github/workflows/sync-catalog.yml` ir
`sync-product-metadata.yml`). VPS nevykdo Chromium rinkimo — jis teikia Supabase API ir
Postgres duomenų bazę.

Vietiniai canary paleidimai buvo laikina integracinė patikra: jie patvirtino, kad rinktuvas
gali pasiekti staging VPS ir įrašyti katalogo duomenis. GitHub paleidimams naudojamas
atskiras `staging` Environment su staging reikšmėmis. Production secrets
(`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`) nekeičiami.

Staging workflow sukurtas, sujungtas į `main` ir sėkmingai paleistas rankiniu
`workflow_dispatch`. Read-model ir VPS cron patikros baigtos; tik dabar galima planuoti
didesnį staging run. Production workflow secrets ir cron nepakeisti.

## Staging adresas

```text
https://supabase-staging.rinkissaupigiausia.online
```

## Staging produkto metadata workflow

Metadata rinkimui naudojamas atskiras rankinis workflow
`.github/workflows/sync-product-metadata-staging.yml`. Jis dalijasi
`catalog-sync-staging` concurrency grupe su katalogo staging workflow, todėl abu
rinkimai negali vienu metu apkrauti ABOUT YOU šaltinio.

GitHub `staging` Environment naudoja tik staging `SUPABASE_URL` ir
`SUPABASE_SERVICE_ROLE_KEY`. Pirmas paleidimas:

1. pasirinkti **Sync product metadata (staging)**;
2. naudoti `max_products=50`;
3. patikrinti `product_detail_sync`, dydžių/spalvų/sekcijų lenteles;
4. patikrinti `sync-raw` ir `sync-debug` Storage objektų count bei bytes;
5. patikrinti, kad read-model refresh baigtas be klaidos.

Workflow sukūrimas nėra sėkmingo canary įrodymas — 2026-07-18 GitHub Actions dar
nebuvo nė vieno `Sync product metadata (staging)` paleidimo.

Sync procesui reikalingi tik serveriniai kintamieji:

```env
SUPABASE_URL=https://supabase-staging.rinkissaupigiausia.online
SUPABASE_SERVICE_ROLE_KEY=<staging VPS service-role key>
SYNC_MAX_PRODUCTS=10
SYNC_HEADLESS=true
```

`SUPABASE_SERVICE_ROLE_KEY` niekada nekeliamas į frontend, Git ar pokalbį.

## Saugos vartai

- Prieš canary patikrinti, kad `SUPABASE_URL` tikrai yra staging hostname.
- Nenaudoti root `.env` perrašymo; kintamuosius nustatyti tik konkretaus proceso sesijoje.
- Pirmam canary naudoti `SYNC_MAX_PRODUCTS=10`.
- Jei targetų nėra arba jie neteisingi, sync nestartuoti.
- Jei `sync_runs` gauna `failed`, sustabdyti ir rinkti logus; dydį didinti tik po patikros.
