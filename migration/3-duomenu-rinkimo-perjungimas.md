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
- [ ] Tik po patvirtinimo svarstomas didesnis staging sync.
- [ ] Production sync ir production cron Å¡ioje fazÄ—je nepakeisti.

**BÅ«sena:** antras staging canary pavyko per 1 min. 26 sek.; 25/25 targetÅ³ baigÄ—si sÄ—kmingai. `SYNC_MAX_PRODUCTS=50` taikomas kiekvienam targetui, todÄ—l paleidimas apÄ—mÄ— iki 1250 produktÅ³ (faktiÅ¡kai kai kurie targetai turÄ—jo maÅ¾iau). Read-model refresh sÄ—kmingas (`34/34`, `refreshed`, `dirty=false`, 2,2 sek.). Production nepakeistas.

**Kitas veiksmas:** antras staging canary su `SYNC_MAX_PRODUCTS=50` (tai reiÅ¡kia iki 50 produktÅ³ kiekvienam aktyviam targetui), tada pakartoti `sync_runs` ir read-model bÅ«senos patikrÄ…. Vykdyti tik kai nevyksta kitas sync.

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

Kitas saugus veiksmas — sukurti atskirÄ… `sync-catalog-staging.yml` workflow su rankiniu
`workflow_dispatch` ir `staging` Environment, paleisti jÄ¯ vienÄ… kartÄ…, patikrinti
`sync_runs` bei read-model, o tik tada planuoti production workflow secrets/cron pakeitimÄ….

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
