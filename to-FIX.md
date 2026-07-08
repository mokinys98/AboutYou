# Metadata sync – ką dar reikia pataisyti

Analizės momentas: 2026-07-07. Parserio versija: `2`.

## Dabartinė būsena

Paskutinio metadata sync rezultatas:

```json
{
  "claimed": 950,
  "payload_ok": 915,
  "complete": 375,
  "source_absent": 375,
  "retryable": 0,
  "blocked_schema": 540,
  "source_unavailable": 10,
  "rate_limited": true,
  "pending": 6249
}
```

`payload_ok` rodiklis yra geras: struktūruotas `GetProductBulk` payload gautas 915 iš 950 aplankytų produktų. Tačiau tik 375 produktai įrašyti kaip `complete`. Tai reiškia, kad užbaigta tik 41 % produktų, kurių payload buvo sėkmingai gautas.

## Pagrindinė problema: `blocked_schema`

540 produktų buvo atmesti dėl dar nepalaikomų, bet teisėtų ABOUT YOU payload variantų:

| Kiekis | Klaidos kodas | Reikalingas pakeitimas |
|---:|---|---|
| 251 | `unknown_detail_lane:sustainabilityInfoLane` | Atpažinti tvarumo informacijos lane kaip žinomą papildomą sekciją arba sąmoningai ignoruojamą lane. |
| 139 | `unknown_size_dimension:pants` | Išanalizuoti `pants` dydžio objektą ir tiksliai išsaugoti liemens bei ilgio dimensijas. |
| 131 | `unknown_size_type:sizeRuns` | Palaikyti kelias dydžių eiles ir jų pasirinkimus neprarandant grupės bei prieinamumo. |
| 19 | `unknown_size_type:oneSize` | Palaikyti vieno dydžio produktus kaip vieną tikslų dydžio pasirinkimą. |

Šios keturios priežastys sudaro visus 540 `blocked_schema` įrašų. Jas sutvarkius, dabartiniai blokuoti produktai turi būti pakartotinai įtraukti į eilę pakėlus `PRODUCT_DETAIL_PARSER_VERSION`.

## Antra problema: rate limit

Sync sustojo po 950 produktų su `rate_limited: true`. Dabartinis `400 ms` tarpas reiškia maždaug 2,5 naujos užklausos per sekundę.

Rekomenduojama:

- padidinti `METADATA_SYNC_DELAY_MS` bent iki `750`;
- pradėti nuo `METADATA_SYNC_CONCURRENCY=2`;
- gavus HTTP 403 arba 429 iš karto stabdyti naujų užklausų planavimą;
- rate-limit bandymo neįtraukti į produkto `attempt_count`;
- po pakeitimo atlikti 500–1000 produktų canary ir tik tada pilną backfill.

## Klaidinantis rodiklis: `source_absent`

`source_absent: 375` šiuo metu skaičiuoja trūkstamas sekcijas, o ne produktus. Todėl jo negalima tiesiogiai lyginti su `complete`.

Pervadinti į `source_absent_sections` ir papildomai loginti:

- `products_with_absent_sections`;
- `complete_products`;
- `present_sections`;
- kiekvienos sekcijos `present` / `source_absent` skaičius.

## Taisymo tvarka

1. Surinkti po kelis sanitizuotus raw fixture kiekvienai iš keturių blokuojamų schemų.
2. Pridėti parserio regresinius testus `sustainabilityInfoLane`, `pants`, `sizeRuns` ir `oneSize` formatams.
3. Įgyvendinti parserio palaikymą neinterpretuojant ar neatspėjant trūkstamų reikšmių.
4. Pakelti parserio versiją iš `2` į `3`, kad `blocked_schema` produktai automatiškai grįžtų į darbo eilę.
5. Sumažinti užklausų tempą ir paleisti ribotą canary.
6. Patikrinti DB suvestinę ir tik tada paleisti likusių produktų backfill.

## Priėmimo kriterijai

- `blockedSchema = 0` žinomoms payload schemoms;
- `complete / payload_ok >= 99 %`;
- likę nebaigti produktai turi konkretų ir pagrįstą `source_unavailable`, `retryable_error` arba naujos nežinomos schemos kodą;
- 1000 produktų canary nepasiekia 403/429;
- kiekvienas `complete` produktas turi raw payload, keturias terminalines sekcijų būsenas ir atominiu būdu įrašytus spalvų bei dydžių pasirinkimus;
- jokia katalogo tile, produkto pavadinimo ar JSON-LD fallback reikšmė nepatenka į autoritetingą produkto-detail modelį.

## Jau patikrinti papildomi formatai

Gyvi testai su produktais `28410256`, `30763734` ir `31866800` patvirtino bei užfiksavo:

- `singleDimension` dydžius;
- `noSiblings` spalvos pasirinkimą;
- struktūruoto payload ir nuotraukų gavimą.

Šie trys testai paleidžiami komanda:

```bash
npm run test:live:metadata
```
