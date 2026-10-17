# TODO: katalogo refresh trukmė ir DB bloat

## Kokią problemą sprendžiame

Katalogo read modelių (`catalog_items_read` ir facet MV) atnaujinimas trunka
ilgai ir gali pasiekti cron 5 min. `statement_timeout`. Norime išsiaiškinti,
ar DB bloat kyla nuo realių sunkių MV atnaujinimų, ar nuo dažnų tuščių `clean`
cron patikrų, ir tik tada pasirinkti cron dažnį, timeout bei cache galiojimą.

## Kas jau žinoma

- Cron grafikas yra `*/5 * * * *`, bet šiuo metu sustabdytas. Jo dažnio dar
  nekeisti.
- Ankstesniame 14 dienų reporto lange buvo 2 212 paleidimų. Tuomet paskutiniuose 60 paleidimų 59
  truko bent 295 s; `cron.job_run_details` neatskleidžia funkcijos JSON statuso.
- Paskutinis patvirtintas pilnas refresh truko 324.124 s. Ankstesnė state
  momentinė būsena turėjo vienos versijos tarpą (`requested_version=3240`,
  `completed_version=3239`); dabartinė būsena pateikta žemiau.
- `clean` šaka neperrefreshina MV, todėl ji negali tiesiogiai sukurti dead
  tuples didžiuosiuose read modeliuose. Esami dead-tuple skaičiai ir statistikos
  neparodo bloat prieaugio vienam konkrečiam refresh.
- Fazių logavimo žymekliai yra DB funkcijose, bet `docker logs` per 24 h ir
  200 h jų nerado. Cron dažnio, timeout ir cache TTL pasirinkimas atviras.

## 2026-10-18 patikros rezultatai

- Per leidžiamą tik skaitymo VPS jungtį patvirtinta: `log_destination=stderr`,
  `logging_collector=off`, `log_min_messages=fatal`. Dabartinių funkcijų
  `RAISE LOG` žinutės dėl `fatal` slenksčio neišsaugomos serverio žurnale.
  Istorinių fazių laikų iš jų atkurti negalima. `codex_reader` jau gali skaityti
  `cron.job` ir `cron.job_run_details`. 2026-10-18 suteikus papildomą teisę,
  per realų prisijungimą patvirtintas ir `pg_current_logfile()` vykdymas;
  funkcija grąžina `NULL`, nes `logging_collector=off`.
- Vėliau naudotojas VPS Docker `psql` sesijoje kaip `supabase_admin` pritaikė
  `GRANT EXECUTE ON FUNCTION pg_catalog.pg_current_logfile() TO codex_reader`:
  pateikta `BEGIN`, `GRANT`, `COMMIT` ir atskiros patikros `allowed=t` išvestis.
  Atskiroje Codex tik skaitymo patikroje per `codex_reader` visos keturios
  [teisių patikros](../../supabase/tests/verify_codex_reader_cron_and_logfile_privileges_read_only.sql)
  reikšmės buvo `true`, o tiesioginis `pg_current_logfile()` iškvietimas pavyko
  ir grąžino `NULL` (kai `logging_collector=off`). Ankstesnis `permission denied`
  įrašas aukščiau yra istorinė būsena iki teisės suteikimo.
- Cron vis dar sustabdytas: `schedule='*/5 * * * *'`, `active=false`.
  Slenkančiame 14 dienų lange rasti 2208 `succeeded` ir 1 `failed` paleidimai;
  paskutiniai devyni sėkmingi cron įrašai truko apie 300 s, tačiau cron būsena
  neatskleidžia funkcijos grąžinto JSON rezultato. Paskutinio įrašo
  `return_message='job canceled'`.
- Būsena dabar `requested_version=3241`, `completed_version=3239`,
  `last_status=pending`. Paskutinis išsaugotas pilno ciklo laikas: 324124 ms.
- Dabartinė DB `catalog_facets_cache` neturi laiku paremto TTL: įrašai
  naudojami iki refresh metu atliekamo ištrynimo. Worker cache šviežumas yra
  5 min., o klaidos atveju jis gali pateikti iki 24 val. senumo atsakymą.
  Naršyklės facet cache TTL taip pat 5 min. DB invalidavimas neišvalo Worker
  arba naršyklės cache, tad po refresh senas atsakymas gali likti 5 min.
- `n_dead_tup` yra statistinis įvertis. Dabartinė viena momentinė lentelių
  statistika neįrodo nei fizinio bloat dydžio, nei vieno refresh prieaugio.
  Prieš/po ciklo reikia išsaugoti
  [šios užklausos](../../supabase/tests/snapshot_catalog_refresh_bloat_read_only.sql)
  rezultatus ir palyginti tik jei `stats_reset_at` nepasikeitė; autovacuum gali
  sumažinti `n_dead_tup` tarp momentinių matavimų.
- Pirmas metrikų migracijos SQL Editor bandymas baigėsi PostgreSQL `42601`
  sintaksės klaida ties `END;` (turėjo būti `END IF;`). Po klaidos per
  [tik skaitymo diagnostiką](../../supabase/tests/diagnose_failed_catalog_refresh_metrics_migration_read_only.sql)
  patvirtinta, kad naujų metrikų objektų nėra, o trijų esamų funkcijų
  apibrėžtys nepasikeitė. Pataisytą migraciją naudotojas paleido SQL Editor:
  pateikta `Success. No rows returned`, todėl VPS pritaikymas patvirtintas.
  Atskiros [įdiegimo patikros](../../supabase/tests/verify_catalog_refresh_metrics_installed_read_only.sql)
  rezultatas: visi objektų, funkcijų įrašymo ir `codex_reader` skaitymo laukai
  `true`, visi `exposed_to_*` laukai `false`, `recorded_runs=0` ir
  `recorded_phases=0`. Codex tą patį patvirtino per tik skaitymo VPS jungtį.
- Po įdiegimo tik skaitymo priešciklinė patikra rado vieną sustabdytą cron job,
  jokių vykstančių cron įrašų ar refresh advisory lock, paruoštą optimizuotą
  size facets MV ir `requested_version=3241`, `completed_version=3239`.
  Tai buvo būsena prieš žemiau aprašytą matuojamą ciklą.

## 2026-10-17 21:11–21:15 UTC matuojamas ciklas

- Naudotojas SQL Editor pateikė tikrąjį
  [prieš matavimą](20261018_catalog_refresh_bloat_before.json) 21:11:32 UTC.
  SQL Editor vienkartinį refresh paleido 21:12:10 UTC. Jo UI parodė
  `invalid_type` / `formattedError` formatavimo klaidą, o ne PostgreSQL
  vykdymo rezultatą. Todėl vien iš UI pritaikymo sėkmė nepatvirtinta.
- Codex per leistiną tik skaitymo jungtį stebėjo to paties SQL Editor proceso
  refresh advisory lock iki ciklo pabaigos. Po jo DB išsaugojo `run_id=1`,
  `outcome=refreshed`, `duration_ms=133407`, `target_version=3241`;
  `completed_version=3241`, `requested_version=3241`. Atskira
  [ciklo patikra](../../supabase/tests/verify_catalog_refresh_measurement_after_cycle_read_only.sql)
  grąžino `outcome_ok`, `phase_count_ok`, `phase_order_ok`,
  `version_completed_ok` ir `cron_still_paused_ok` = `true`. Visos 9 fazės
  sėkmingos ir teisinga tvarka; užrakto nebeliko. Tai patvirtina DB rezultatą,
  nors SQL Editor UI rezultatas nebuvo sėkmės įrodymas.
- Fazės: `catalog_items_read` 26 456 ms, jo `ANALYZE` 2 543 ms,
  `catalog_item_facet_values_read` 58 766 ms, `catalog_size_facets_read`
  28 636 ms, jo `ANALYZE` 258 ms, `effective_size_membership` 11 857 ms,
  `static_size_facets_cache` 924 ms, `facet_cache_delete` 19 ms ir
  `root_facet_cache_prewarm` 3 935 ms. Lėčiausia buvo facet reikšmių MV fazė.
- Codex 21:15:20 UTC paėmė [po matavimą](20261018_catalog_refresh_bloat_after.json).
  `stats_reset_at` abiejose kopijose `NULL`, nė vieno stebimo MV heap dydis
  nepadidėjo. `catalog_items_read` `n_dead_tup` įvertis pakilo nuo 0 iki
  13 975, o jo heap ir indeksų dydžiai nepakito. `catalog_size_facets_read`
  indeksai padidėjo 8 192 baitais; dviejų mažų cache lentelių bendras dydis
  padidėjo 49 152 ir 24 576 baitais. Taigi realus refresh sukūrė dead tuple
  įvertį, bet vienas ciklas neįrodo fizinio MV bloat augimo. Šie statistikos
  įverčiai gali dar pasikeisti po ciklo ir autovacuum.
- `catalog_items_read` autovacuum baigėsi 21:16:19 UTC: `autovacuum_count`
  padidėjo nuo 361 iki 362, o `n_dead_tup` įvertis nukrito iki 0. 21:17:36 UTC
  tik skaitymo patikroje cron vis dar sustabdytas, versijos sutampa,
  naujausias ciklas truko mažiau nei 5 min., visos 9 fazės sėkmingos,
  autovacuum sąlyga įvykdyta ir refresh užrakto nėra. Tai leidžia grąžinti
  tą patį cron grafiką stebėjimui, nekeičiant timeout ar cache TTL.
- Naudotojas 21:20 UTC SQL Editor paleido apsaugotą cron grąžinimą ir pateikė
  `Success. No rows returned`. Codex atskira tik skaitymo patikra 21:20:07 UTC
  patvirtino `job_active=true`, `configuration_ok=true`, `measured_run_ok=true`
  ir `post_refresh_autovacuum_ok=true`. Pirmas natūralus cron darbas 21:20:00 UTC
  įrašė `run_id=2`, `outcome=clean`, `duration_ms=3`; `cron.job_run_details`
  atskirai rodo `succeeded`. Taigi `clean` šaka nesukūrė nė vieno fazės įrašo.
- [Po pirmo natūralaus `clean` paimta kopija](20261018_catalog_refresh_after_first_clean.json)
  parodė, kad visuose šešiuose stebimuose objektuose `n_tup_ins`, `n_tup_del`,
  heap, indeksų ir bendro failų dydžio pokytis nuo ankstesnės kopijos buvo 0.
  Pagrindinio MV `autovacuum_count` padidėjo 1 po ankstesnio sunkaus ciklo;
  tai nėra `clean` sukurtas MV įrašymas.
- Antras natūralus `clean` 21:25:00 UTC taip pat truko 3 ms (`run_id=3`).
  [Mažųjų lentelių prieš](20261018_clean_small_tables_before.json) ir
  [po](20261018_clean_small_tables_after.json) kopijos parodė tiksliai vieną
  naują `catalog_read_model_refresh_state` `UPDATE` ir `n_dead_tup` įverčio
  prieaugį 1; `catalog_refresh_runs` gavo vieną naują eilutę, fazių lentelė
  nepasikeitė. Visų trijų lentelių heap, indeksų ir bendras dydis nepadidėjo.
  Todėl tušti `clean` patikrinimai turi mažą rašymo kainą, bet nesukuria
  didžiųjų MV dead tuples ar pastebimo failų augimo šiame intervale. 15 s
  stebėsenos kopijos tiesiai prieš ir po šio cron darbo papildomai parodė
  nulinius `n_tup_ins`, `n_tup_upd`, `n_tup_del`, `n_dead_tup` ir visų dydžių
  pokyčius kiekviename iš šešių stebimų katalogo objektų.

## TODO: vykdymo seka

- [x] TODO 1. Patikrinti logų nustatymus su
  [tik skaitymo užklausa](../../supabase/tests/diagnose_catalog_refresh_logging_read_only.sql).
  `RAISE LOG` įrašai nuslopinti `log_min_messages=fatal`, todėl istorinių fazių
  trukmių nėra iš kur paimti.
- [x] TODO 2. Parengti
  [išliekančių run/phase metrikų migraciją](../../supabase/migrations/20261018100000_persist_catalog_refresh_metrics.sql).
  Ji skiria `busy`, `clean`, `refreshed`, `failed` ir saugo sėkmingų fazių
  trukmes. Nepavykus refresh, ankstesnių sėkmingų fazių įrašai atšaukiami kartu
  su DB pakeitimais, bet jų trukmės perduodamos išoriniam klaidos tvarkytuvui
  ir iš naujo įrašomos su nepavykusios fazės trukme bei viso ciklo laiku.
  **Migracija VPS pritaikyta; pirmojo realaus ciklo 9 fazių metrikos išsaugotos.**
- [x] TODO 3. Patikrinti DB, Worker ir naršyklės cache TTL bei invalidavimą;
  rezultatai užrašyti aukščiau.
- [x] TODO 4. Supabase SQL Editor įkelti ir paleisti visą naujausią metrikų
  migracijos failą. SQL Editor grąžino `Success. No rows returned`; cron ir
  cache parametrai nekeisti.
- [x] TODO 5. SQL Editor paleisti
  [įdiegimo patikrą](../../supabase/tests/verify_catalog_refresh_metrics_installed_read_only.sql).
  Tikėtina viena eilutė: visi `*_installed`, `*_records_*` ir
  `reader_can_select_*` laukai `true`, visi `exposed_to_*` laukai `false`.
  Naudotojo pateiktoje rezultato eilutėje visi laukai atitiko lūkesčius,
  `recorded_runs=0`, `recorded_phases=0`. Atskirai patikrinta per `codex_reader`.
- [x] TODO 6. Prieš kitą realų refresh paleisti ir išsaugoti
  [lentelių statistikos momentinį matavimą](../../supabase/tests/snapshot_catalog_refresh_bloat_read_only.sql).
  Naudotojo 21:11:32 UTC rezultatas išsaugotas kaip tikras prieš matavimas.
- [x] TODO 7. Kol cron sustabdytas, SQL Editor paleisti
  [vieno laukiančio refresh matavimą](../../supabase/migrations/manual/measure_pending_catalog_refresh_once.sql).
  SQL Editor UI rodė formatavimo klaidą, tačiau DB tik skaitymo patikra
  patvirtino vieną užbaigtą `refreshed` ciklą. Nekartoti.
- [x] TODO 8. Iškart po ciklo pakartoti 6 žingsnio momentinį matavimą ir
  paleisti [ciklo patikrą](../../supabase/tests/verify_catalog_refresh_measurement_after_cycle_read_only.sql)
  bei [metrikų santrauką](../../supabase/tests/diagnose_catalog_refresh_metrics_read_only.sql).
  Codex atliko tik skaitymo patikras ir išsaugojo po matavimą bei 9 fazes.
  Cron tebėra sustabdytas; jo ankstesnė istorija patikrinta per tik skaitymo
  jungtį. Tolimesniam stebėjimui parengta
  [cron istorijos užklausa](../../supabase/tests/diagnose_catalog_refresh_run_history_read_only.sql).
- [x] TODO 9. SQL Editor vieną kartą paleisti
  [apsaugotą cron grąžinimą](../../supabase/migrations/manual/20261018_resume_catalog_refresh_for_metrics.sql).
  Jis prieš aktyvavimą patikrina paskutinį išmatuotą sėkmingą ciklą, visas
  fazes, uždarytą versijų tarpą, autovacuum ir cron darbo tapatybę. Grafikas,
  komanda, timeout ir cache TTL nesikeičia. Po to atlikti atskirą
  [tik skaitymo patikrą](../../supabase/tests/verify_catalog_refresh_metrics_cron_resumed_read_only.sql).
  **Pritaikyta VPS ir atskirai patikrinta per `codex_reader`.**
- [ ] TODO 10. Po cron grąžinimo surinkti bent kelis natūralius `refreshed`
  ciklus ir `clean`/`busy` bei timeout pasiskirstymą, kiekvienam sunkiajam
  ciklui išsaugant prieš/po statistiką. Codex skaitymo patikras atlieka pats;
  ribota 15 s dažnio [tik skaitymo stebėsena](../../scripts/benchmarks/catalog_refresh_bloat_watch.py)
  rašo vietines kopijas į `artifacts/catalog_refresh_bloat_watch_20261018.jsonl`.
- [ ] TODO 11. Pagal išmatuotą trukmių pasiskirstymą, autovacuum ir failų
  dydžio pokytį siūlyti cron grafiką, timeout ir cache galiojimą. Iki tol jų
  parametrų nekeisti.
