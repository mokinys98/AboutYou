# Techninių darbų planas

**Bendras progresas:** 45/100  
**Būsena:** sujungti nebaigti techniniai darbai ir sąlyginiai patobulinimai

## 1. Admin dashboard stabilizavimas

**Progresas:** 35/100

### Atlikta

- [x] Dashboard count užklausos perkeltos nuo gyvo `catalog_items` į
  `catalog_items_read`.
- [x] Nekeshuotas kategorijų agregavimas pakeistas `catalog_facets_cached`.
- [x] UI naudoja izoliuotą panelių krovimą, todėl vieno endpointo klaida nenumuša
  viso admin puslapio.
- [x] Pridėti loginiai DB operacijų pavadinimai, trukmės ir klaidų diagnostika.
- [x] Pridėti regresiniai testai.

### Dar reikia

- [ ] Produkcijoje surinkti bent 30 dashboard užkrovimų ir patikimą stebėjimo langą.
- [ ] Užfiksuoti p50, p95, maksimumą, 200/500 santykį ir statement timeout skaičių.
- [ ] Sukurti vieną `admin_dashboard_stats()` RPC visai suvestinei.
- [ ] Sumažinti pradinį admin bootstrap iki 1–2 Worker endpointų.
- [ ] Pašalinti pasikartojančias `team_members` patikras.
- [ ] Pasiekti dashboard p95 mažiau nei 2 s.
- [ ] Jei katalogo augimas vis dar veikia admin našumą, sukurti inkrementines
  `admin_catalog_stats`, `admin_brand_stats` ir `admin_category_stats` lenteles.

### Uždarymas

- [ ] Baigta – galima ištrinti

## 2. Raw payload perkėlimas į Storage

**Progresas:** 75/100

### Atlikta

- [x] Sukurti privatūs `sync-raw` ir `sync-debug` bucket’ai.
- [x] Sukurtas `product_sync_artifacts` manifestas ir sample membership.
- [x] Metadata canary sėkmingai įrašė fizinį gzip objektą.
- [x] Patikrintas authenticated Storage nuskaitymas ir gzip vientisumas.
- [x] API debug kelias skaito naujus Storage artefaktus.

### Dar reikia

- [ ] Patikrinti, ar visi atrinkti archyvo sample nariai turi `ready` artefaktą.
- [ ] Patvirtinti, kad naujas metadata sync nebedidina `product_detail_raw`.
- [ ] Priimti sprendimą dėl senų `sync-raw` / `sync-debug` objektų istorijos.
- [ ] Sukurti atskirą guarded finalization migraciją.
- [ ] Tik po archyvo patikros pašalinti seną `complete_product_detail` suderinamumo
  funkciją ir `product_detail_raw` lentelę.
- [ ] Po finalizavimo patikrinti DB dydį, security advisor ir performance advisor.

### Uždarymas

- [ ] Baigta – galima ištrinti

## 3. Katalogo read modelio tolesnis vystymas

**Dabartinio stabilizavimo progresas:** 100/100  
**Inkrementinio modelio progresas:** 0/100, vykdyti tik atsiradus poreikiui

Versijuotas refresh, advisory lock, dirty state, 90 s vidinis timeout ir `pg_cron`
įgyvendinti bei patikrinti. Pilnas materialized view rebuild vis dar yra brangi
operacija, todėl inkrementinis modelis paliekamas kaip sąlyginis ateities darbas.

- [ ] Pradėti tik jei refresh p95 išlieka virš 45 s, kartojasi DB I/O timeout,
  katalogas ženkliai išauga arba 5 minučių atsilikimas tampa nepriimtinas.
- [ ] Registruoti pasikeitusių produktų ID.
- [ ] Batch būdu upsertinti tik pasikeitusias katalogo eilutes.
- [ ] Perrašyti tik pakeistų produktų facet reikšmes.
- [ ] Prieš API perjungimą palyginti seno ir naujo modelio rezultatus.
- [ ] Turėti aiškų rollback kelią.

### Uždarymas

- [ ] Baigta – galima ištrinti

## 4. Mažesnis produkto ir operacijų backlog

**Progresas:** 0/100

- [ ] Suprojektuoti vartotojo individualius brand tier override’us, nekeičiant
  globalių default reikšmių.
- [ ] Patikrinti, kad Telegram profilio susiejimo ir atjungimo UX yra aiškus.
- [ ] Iš žinomų ABOUT YOU duomenų spragų pasirinkti tik verslo verte pagrįstus naujus
  atributus.
- [ ] Periodiškai peržiūrėti VPS disko, WAL, inode ir backup augimą.

### Uždarymas

- [ ] Baigta – galima ištrinti
