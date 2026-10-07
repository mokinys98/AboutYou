# Katalogo atnaujinimo fazių trukmės matavimo planas

## Tikslas

Nustatyti, kurios `process_catalog_items_read_refresh()` fazės sudaro beveik 300 s trukmę, ir tik tada rinktis konkrečią optimizaciją. Matavimas turi parodyti kiekvienos fazės pradžią, pabaigą, trukmę ir atnaujinimo versiją. Esamas `pg_stat_activity` grafikas rodo visos transakcijos trukmę, o ne jos vidines fazes.

Paskutinis pateiktas sėkmingas ciklas truko **279 415 ms**. Funkcija vykdoma su **5 min. `statement_timeout`**, todėl liko apie 20,6 s atsarga.

## Dabartinė fazių seka

Pagal repozitorijos migracijas atnaujinimas vykdo šiuos darbus iš eilės:

1. `catalog_items_read` materializuoto vaizdo atnaujinimas.
2. `ANALYZE catalog_items_read`.
3. `catalog_item_facet_values_read` materializuoto vaizdo atnaujinimas.
4. `catalog_size_facets_read` materializuoto vaizdo atnaujinimas.
5. `ANALYZE catalog_size_facets_read`.
6. `catalog_effective_size_membership_read` materializuoto vaizdo atnaujinimas.
7. `static_size_facets_cache` grupavimas, JSONB sudarymas ir cache eilutės įrašymas.
8. `catalog_facets_cache` išvalymas.
9. Šakninio facet cache paruošimas kviečiant `catalog_facets_cached('{}')`.

## Matavimo eiga

### 1. Užfiksuoti pradinę būseną

Prieš keičiant funkcijas, tik skaitomomis SQL užklausomis užfiksuoti:

- aktyvios `pg_cron` užklausos PID, pradžios laiką, `query_age`, `wait_event` ir užklausos tekstą;
- `requested_version`, `completed_version`, `last_status`, `last_duration_ms`, `last_error`, pradžios ir pabaigos laikus;
- gyvus VPS funkcijų apibrėžimus ir jų savininkus, kad vietinė migracija būtų pritaikoma tik tada, jei VPS apibrėžimai atitinka numatytą bazę.

Naujo atnaujinimo rankiniu būdu nesukelti. Matuoti natūraliai suplanuotą ciklą.

### 2. Pridėti mažos apimties fazių žurnalavimą

Parengti atskirą SQL Editor suderinamą migraciją, kuri kiekvienai aukščiau išvardytai fazei užfiksuotų:

- atnaujinimo versiją ir `pg_backend_pid()`;
- fazės pavadinimą;
- fazės pradžios UTC laiką ir trukmę milisekundėmis;
- sėkmės arba klaidos būseną.

Fazės įrašą generuoti iškart po fazės naudojant `clock_timestamp()` ir `RAISE LOG`. Versiją perduoti į vidines fazes transakcijos lokaliu kontekstu iš `process_catalog_items_read_refresh()`, o žurnalo koreliacijos raktą sudaryti iš versijos, PID ir ciklo pradžios laiko. Duomenų bazės žurnalo įrašai lieka matomi ir tada, jei vėlesnė fazė atšaukiama dėl timeout. Esamą `last_error` palikti nepakeistą; papildomai užfiksuoti ir paskutinės nepavykusios fazės trukmę.

Prieš rengiant migraciją, perskaityti gyvą VPS funkcijų apibrėžimą ir patikrinti savininką. Nekeičiant savininko ar teisių, migracijos netaikyti, jeigu dabartinė funkcija skiriasi nuo numatytos bazės arba ją keičiančiam vaidmeniui trūksta nuosavybės teisių. VPS pakeitimą naudotojas paleidžia rankiniu būdu Supabase SQL Editor pagal projekto migracijų tvarką.

### 3. Stebėti ciklus

Po migracijos surinkti bent **3 natūraliai įvykusių sėkmingų ciklų** fazių žurnalus ir atitinkamas `catalog_read_model_refresh_state` eilutes. Jei ciklas nepavyksta savaime, išsaugoti klaidos fazės įrašą; klaidos tyčia neprovokuoti.

Kiekvienam ciklui palyginti:

- visų fazių trukmių sumą;
- `last_duration_ms` bendrą ciklo trukmę;
- pradžios ir pabaigos laikus;
- `requested_version` ir `completed_version` skirtumą.

Fazių suma turi paaiškinti beveik visą bendrą laiką. Likęs skirtumas gali būti funkcijų paleidimo, būsenos atnaujinimo ir logavimo išlaidos.

### 4. Tirti lėčiausią fazę

Tik identifikavus lėčiausią fazę, tirti jos šaltinio SQL planą. Perskaityti atitinkamą materializuoto vaizdo apibrėžimą arba funkcijos SQL ir vieną fazę vienu metu įvertinti ne piko metu su `EXPLAIN (ANALYZE, BUFFERS)`. Vertinti:

- `actual rows` prieš planuotas eilutes;
- sekvencinius ir indeksinius skaitymus;
- `shared hit/read/dirtied/written` buferius;
- laikinus blokus ir rūšiavimo / grupavimo mazgus;
- fazei skirtą laiką ir iš I/O laikų matomą skaitymo kainą, jei `track_io_timing` jau įjungtas.

Nenaudoti `EXPLAIN ANALYZE` visam `REFRESH MATERIALIZED VIEW` procesui ir nevykdyti viso refresh vien diagnostikos tikslais. Jei `track_io_timing` išjungtas, pirmiausia pateikti tik skaitomą nustatymo patikrą; jo įjungimą svarstyti atskirai, nes tai jau būtų duomenų bazės konfigūracijos pakeitimas.

## Saugikliai

- Nekelti `statement_timeout` ir nekeisti refresh tvarkos per šį matavimo etapą.
- Nekeisti PostgreSQL vaidmenų, funkcijų savininkų ar prieigos teisių.
- Nematuoti visų sunkių fazių `EXPLAIN ANALYZE` vienu metu; tai papildomai apkrautų DB.
- Fazės metaduomenyse nefiksuoti SQL parametrų, prisijungimo duomenų ar produktų duomenų.
- Nauji metrikų grafikai ar Prometheus eksportas nėra pirmo etapo dalis. Pirmiausia pakanka patikimų fazių laikų duomenų bazės žurnaluose.

## Baigimo kriterijai

Matavimo etapas baigtas, kai:

1. bent 3 sėkmingiems ciklams išsaugotos visų fazių trukmės;
2. lėčiausia fazė ir jos trukmės svyravimas aiškūs;
3. fazių suma sutampa su `last_duration_ms` iki 5 % arba paaiškintas skirtumas;
4. yra pakankamai įrodymų pasirinkti vieną optimizavimo kryptį, o ne keisti serverio resursus spėjimo būdu.

Po šių matavimų atskirai parengti optimizavimo pasiūlymą ir jo saugų patikros planą.

## Įgyvendinimo ir before / after žurnalas

### Before: iki fazių žurnalavimo

- 2026-10-07 naudotojo pateiktas ciklas: `refresh_started_at = 19:40:00.029727 UTC`, `refresh_completed_at = 19:44:39.445802 UTC`, `last_duration_ms = 279415`, `last_status = refreshed`; versijų skaitikliai tuo metu buvo `requested_version = 2338`, `completed_version = 2337`.
- 2026-10-07 20:01:13 UTC per read-only VPS tunelį patikrintas paskutinis ciklas: `refresh_started_at = 19:55:00.025269 UTC`, `refresh_completed_at = 19:59:20.410896 UTC`, `last_duration_ms = 260385`, `last_status = clean`; `requested_version = completed_version = 2339`.
- Iki fazių logavimo nebuvo atskirų sėkmingų fazių trukmių. Šie bendri laikai yra palyginimo bazė, ne fazių analitika.

### Fazių žurnalavimo pakeitimas

Parengta [20261007200200 fazių žurnalavimo migracija](../../supabase/migrations/20261007200200_instrument_catalog_refresh_phase_timings.sql) ir [read-only patikros užklausa](../../supabase/tests/verify_catalog_refresh_phase_logging_read_only.sql). Migracija įrašo kiekvienos fazės pavadinimą, pradžios UTC laiką, trukmę, rezultatą, refresh versiją ir PID į PostgreSQL žurnalą. Ji nekeičia refresh tvarkos, timeout, savininkų ar teisių ir pati refresh nepaleidžia.

**VPS būsena: migracija pritaikyta ir read-only patikra sėkminga.** Naudotojas pateikė SQL Editor rezultatą „Success. No rows returned“. 2026-10-07 20:09:32 UTC patikrinta, kad visos trys funkcijos turi numatytus žurnalavimo žymeklius, išlieka `SECURITY DEFINER` ir priklauso `postgres`. Po migracijos dar nebuvo refresh ciklo: būsena buvo `requested_version = completed_version = 2339`, `last_status = clean`, o aktyvių užklausų nebuvo. Todėl „after“ fazių laikų dar nėra ir greičio pagerėjimo negalima skelbti.

Žurnalo įrašai atsiras tik tada, kai įprastas katalogo srautas pateiks naują refresh prašymą (`requested_version > completed_version`). Vien cron patikros ciklas, radęs būseną `clean`, fazių nevykdo ir jų laikų nerašo. Naujo atnaujinimo rankiniu būdu nesukelti.

Fazių `outcome=success` žinutė reiškia, kad baigėsi ta fazė. Jei vėliau visas refresh atšaukiamas, ankstesnių fazių DB pakeitimai atšaukiami, nors jų logai lieka. Todėl ciklą laikyti sėkmingu tik tada, kai tam pačiam `run_id` yra `catalog_refresh_run outcome=success` eilutė ir visos devynios fazės. `outcome=failed` ciklo fazių laikus naudoti tik klaidos vietai nustatyti, ne sėkmingų ciklų sumai lyginti.

VPS Postgres konteinerio žurnalui nuskaityti po migracijos galima naudoti read-only komandą: `docker logs --since=2h supabase-db 2>&1 | grep 'catalog_refresh_'`. Žurnalų eilutes grupuoti pagal `run_id`; slaptažodžių ar užklausų parametrų žurnalavimo migracija nedaro.

After palyginime kartu išsaugoti versiją, bendrą laiką, visų devynių fazių laikus, `last_status` ir ar ciklo metu atsirado naujas prašymas (`requested_version > completed_version`). Žurnalavimo tikslas yra matavimas; ši migracija pati nėra našumo optimizacija.
