# DB bloat ir katalogo refresh incidentas — 2026-10-11

## Būsena

- Negyvų eilučių valymas `public.catalog_items_read` **sėkmingai įvykdytas** naudotojo VPS.
- Lentelės heap dydis sumažėjo nuo maždaug 38 GB iki maždaug 1,4 GB; po valymo bendras lentelės ir indeksų dydis buvo apie 6,6 GB.
- Katalogo refresh problema **neišspręsta**: po valymo naujas ciklas vis tiek baigėsi `statement timeout`, dabar jau `effective_size_membership` fazėje.
- Nėra patvirtinimo, kad metadata sync workflow po eilės reset buvo paleistas ar sėkmingai apdorojęs naujus įrašus.
- VPS pakeitimų Codex neatliko. `VACUUM` komandą VPS terminale paleido naudotojas; Codex tik patikrino rezultatą per read-only DB tunelį.

Visi žemiau pateikti DB laikai yra UTC. Eilučių skaičiai `pg_stat_user_tables` yra įverčiai, ne tikslus `COUNT(*)`.

## Eiga ir įrodymai

### Metadata eilės reset

Naudotojas paleido vienkartinį `supabase/manual/20261010_requeue_expired_metadata_leases.sql` SQL Editor. Po jo pateikta patikra rodė:

- `expired_processing_leases = 0`;
- `due_pending = 18 952` (buvo 18 922; 30 pasibaigusių lease grąžintos į eilę);
- `due_retryable = 8 617`.

Šis veiksmas ištrynė ne produkto duomenis, o tik išvalė 30 pasibaigusių lease ir grąžino jų eilutės būseną į `pending`. Vėlesnio sync workflow rezultato šiame užraše nėra.

### Pirmas VACUUM bandymas ir shared memory

Pirmas `VACUUM (VERBOSE, ANALYZE) public.catalog_items_read` nutrūko su:

```text
could not resize shared memory segment ... to 8388608 bytes: No space left on device
CONTEXT: while scanning block 2130431 of relation "public.catalog_items_read"
```

VPS patikros rezultatai:

- hosto `/dev/shm`: 5,9 GB, tuo metu laisva visa talpa;
- PostgreSQL konteinerio `/dev/shm`: 64 MB, naudota 2,2 MB, laisva 61,8 MB;
- konteinerio `ShmSize`: 67 108 864 baitai (64 MiB).

VPS read-only patikra patvirtino PostgreSQL 17.6 ir `dynamic_shared_memory_type = posix`. Šie duomenys rodo mažą konteinerio shared-memory limitą, tačiau po nesėkmės atliktas `df` neįrodo, kad būtent tuo momentu visa talpa buvo užimta.

### Sėkmingas VACUUM be lygiagretaus index valymo

Naudotojas paleido:

```bash
docker exec supabase-db psql -U postgres -d postgres -c 'VACUUM (VERBOSE, PARALLEL 0) public.catalog_items_read;'
```

Komanda baigėsi `VACUUM` pranešimu. Išvestyje nurodyta:

- vykdymo laikas apie **1 457 s** (24 min. 17 s);
- nuskaityta **5 032 124** heap puslapių;
- pašalinta **4 899 370** puslapių, liko **132 754**;
- pašalinta **14 093 528** eilučių versijų;
- **0** eilučių liko „dead but not yet removable“ būsenoje;
- reikėjo 2 index scan; iš indeksų pašalinta **24 337 846** negyvų item ID.

Išvesties pranešimai `suspending truncate due to conflicting lock request` valymo nesustabdė: puslapiai buvo trumpinami toliau, o VACUUM sėkmingai užsibaigė. Pagal 8 KiB PostgreSQL puslapį pašalinti puslapiai sudaro apie **37,4 GiB**.

### Dydžiai po valymo ir atsinaujinęs refresh timeout

2026-10-10 23:09:55 UTC read-only patikra rodė:

| Rodiklis | Reikšmė |
|---|---:|
| `catalog_items_read` gyvų eilučių įvertis | 105 475 |
| negyvų eilučių įvertis | 647 944 |
| `last_vacuum` | 2026-10-10 22:29:17 UTC |
| heap | 1 373 MB |
| indeksai | 5 235 MB |
| bendra lentelės vieta | 6 609 MB |

Kita patikra po kelių sekundžių rodė 1 407 MB heap, 5 235 MB indeksų, 6 642 MB iš viso ir 740 661 negyvų eilučių įvertį. Statistikos įverčiai ir dydžiai kinta; reikšmės nebūtinai reiškia, kad pats VACUUM nepavyko.

2026-10-10 23:10:05 UTC `catalog_read_model_refresh_state` rodė:

- `requested_version = 2632`, `completed_version = 2476`, atsilikimas **156**;
- `last_status = failed`, trukmė **300 365 ms**;
- ciklas prasidėjo **23:05:03.401 UTC**, baigėsi **23:10:03.768 UTC**;
- klaidos fazė: `invalidate_catalog_facets_cache`; jos viduje `effective_size_membership` baigėsi po **131 859 ms** su `canceling statement due to statement timeout`;
- patikros metu aktyvių DB užklausų nebuvo.

Taigi `catalog_items_read` bloat reikšmingai sumažėjo, bet refresh grandinė tebėra nestabili. Negyvų eilučių įverčio padidėjimas po VACUUM laike sutampa su nauju nepavykusiu refresh ciklu; ryšys tikėtinas, bet vien šis sutapimas neįrodo, kad visos naujos negyvos versijos atsirado būtent dėl šio bandymo.

## Dabartinė lėta fazė

VPS klaidos tekste vidinė `effective_size_membership` fazė atitinka:

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY
  public.catalog_effective_size_membership_read;
```

Lokalioje migracijoje [20261007200200_instrument_catalog_refresh_phase_timings.sql](../../supabase/migrations/20261007200200_instrument_catalog_refresh_phase_timings.sql) ši komanda yra `invalidate_catalog_facets_cache()` pradžioje. Materializuotas modelis skaičiuojamas iš `catalog_size_facets_read_effective`, grupuojant pagal produkto ID, dydžio domeną ir dydžio rakto laukus.

Po incidento modelio read-only statistika buvo apie 372 333 gyvų eilučių, 3 496 negyvų eilučių, 54 MB heap, 36 MB indeksų ir 90 MB iš viso. Mažas galutinio materializuoto vaizdo dydis savaime nereiškia, kad jo šaltinio užklausa pigi: šaltinio vaizde atliekama dydžių normalizacija, išraiškų skaičiavimas, galimas dydžių išplėtimas ir grupavimas. Tai tikrintina hipotezė, ne patvirtinta lėto plano priežastis.

## Rytojaus siūlomas tęsinys

1. **Daugiau nebekartoti VACUUM dabar.** Sėkmingas valymas patvirtintas; `VACUUM FULL` ir aklas `REINDEX` nenaudoti. Indeksai vis dar sudaro apie 5,2 GB, bet vien dydis neįrodo, kad juos reikia perkurti.
2. **Užfiksuoti naują read-only atskaitos tašką**: refresh versijų skirtumą, paskutinę klaidą ir laiką, `catalog_items_read` bei `catalog_effective_size_membership_read` dydžius / eilučių įverčius, autovacuum laikus, konteinerio `/dev/shm` ir aktyvias DB užklausas.
3. **Patikrinti VPS įdiegtą tikrą apibrėžimą** `pg_get_viewdef('public.catalog_size_facets_read_effective'::regclass, true)` bei `catalog_effective_size_membership_read` matview apibrėžimą. Palyginti jį su vietinėmis migracijomis, nes repo failas vienas pats neįrodo, koks kodas dabar įdiegtas VPS.
4. **Pirmiausia gauti neanalitinį planą**, tada ramios apkrovos lange atlikti apribotą `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` šaltinio SELECT. `ANALYZE` vykdo realią užklausą ir gali apkrauti DB, todėl nustatyti trumpą `statement_timeout` ir nestartuoti refresh rankiniu būdu diagnostikos metu.
5. **Pagal planą tikrinti** skenavimo eilučių neatitikimus, `catalog_size_facets_read` ir override lentelių indeksus, funkcijų (ypač normalizavimo) skaičių per eilutę, grupavimo/sortavimo spill į temp failus ir nested loop eilučių sprogimą. Keisti tik patvirtintą brangiausią etapą.
6. **Nedidinti 5 min. timeout kaip pirmo taisymo.** Ciklas jau trunka apie 300 s ir nauja klaida dabar atsiranda `effective_size_membership` fazėje. Timeout didinimas galėtų pailginti apkrovą ir dar labiau atitolinti ciklus.
7. **Po pataisos stebėti bent kelis natūralius ciklus**: `last_status` ne `failed`, `completed_version` pasiveja `requested_version`, dead tuple įverčiai neauga sparčiau už valymą, API katalogo/facetų endpointai atsako sėkmingai.
8. **Metadata sync tęsti atskirai ir ribotai.** Eilės resetas patvirtino 30 expired lease atkūrimą, tačiau 18 952 pending ir 8 617 due retryable įrašai yra didelė eilė. Pirma patikrinti paskutinį workflow rezultatą, tada paleisti 50 produktų canary su serializuotu, lėtu tempu; nepaleisti 10k darbo kaip „reset“.

## Faktai ir išvados

- **Patvirtinta:** `VACUUM (VERBOSE, PARALLEL 0)` pavyko ir pašalino milijonus tuple versijų bei didžiąją dalį heap puslapių.
- **Patvirtinta:** iškart po valymo `catalog_items_read` bendras dydis buvo apie 6,6 GB, iš kurių apie 5,2 GB indeksai.
- **Patvirtinta:** katalogo refresh po to vėl baigėsi statement timeout `effective_size_membership` fazėje; versijų atsilikimas buvo 156.
- **Hipotezė:** brangiausia vieta yra efektyvių dydžių šaltinio view normalizavimo / grupavimo kelias. Tam būtinas VPS apibrėžimas ir vykdymo planas.
- **Nežinoma:** ar naujas refresh timeout sukūrė visus po VACUUM matytus ~0,65–0,74 mln. dead tuple įvertį; ar metadata workflow jau buvo paleistas po eilės reset.
