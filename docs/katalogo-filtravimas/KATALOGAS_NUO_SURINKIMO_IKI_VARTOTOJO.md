# Katalogo kelias: nuo surinkimo iki vartotojo

Šis dokumentas atskiria tris skirtingus procesus: prekių surinkimą, DB read modelių atnaujinimą ir svetainės užklausas. `5 min.` grafikas yra Supabase `pg_cron` konfigūracija, o ne rastas aiškus produkto šviežumo reikalavimas. Pagal paskutinę vartotojo patikrą (2026-10-17) šis jobas yra pristabdytas.

## Visas duomenų srautas

```mermaid
flowchart LR
  subgraph SOURCES[Duomenų surinkimas ir pakeitimai]
    CF15[Cloudflare Cron kas 15 min.] -->|workflow_dispatch| GHA[GitHub Actions sync-catalog.yml]
    GHA --> Q[Sync queue: renka katalogo puslapius ir įrašo partijas]
    Q --> SRC[(products ir susiję šaltinio duomenys)]
    Q -->|jei buvo įrašų: request_catalog_items_read_refresh| REQ[requested_version padidinama]
    META[Metaduomenų workflow kas valandą] --> SRC
    META -->|jei pakeitė katalogo duomenis| REQ
    ADMIN[Admin API: brand tier pakeitimas] --> SRC
    ADMIN -->|po pakeitimo| REQ
  end

  subgraph READMODEL[Supabase read modelių atnaujinimas]
    CRON[pg_cron grafikas kas 5 min.; dabar pristabdytas] --> PROC[process_catalog_items_read_refresh]
    REQ --> STATE[(catalog_read_model_refresh_state)]
    STATE --> PROC
    PROC --> CHECK{requested_version > completed_version?}
    CHECK -->|ne| CLEAN[Statusas clean; brangaus darbo nėra]
    CHECK -->|taip| LOCK{Pavyko gauti advisory lock?}
    LOCK -->|ne| BUSY[Statusas busy; kitas vykdymas jau dirba]
    LOCK -->|taip| P1[1. REFRESH catalog_items_read CONCURRENTLY]
    P1 --> P2[2. ANALYZE catalog_items_read]
    P2 --> P3[3. REFRESH catalog_item_facet_values_read]
    P3 --> P4[4. REFRESH optimizuoto catalog_size_facets_read]
    P4 --> P5[5. ANALYZE catalog_size_facets_read]
    P5 --> P6[6. REFRESH catalog_effective_size_membership_read]
    P6 --> P7[7. Perskaičiuoti static size facets cache]
    P7 --> P8[8. Išvalyti catalog_facets_cache]
    P8 --> P9[9. Paruošti root facet cache]
    P9 --> DONE[completed_version pasiveja apdorotą versiją]
    DONE --> STATE
    FAIL[Timeout/kita klaida: įrašomas failed ir last_error] -.-> STATE
  end

  subgraph WEBSITE[Svetainės užklausa]
    USER[Vartotojas atidaro katalogą arba pakeičia filtrą] --> WEB[Web puslapis: produktai ir facetai užkraunami lygiagrečiai]
    WEB --> API_PRODUCTS[API GET /v1/catalog]
    WEB --> API_FACETS[API GET /v1/catalog/facets]
    API_PRODUCTS --> EDGE_PRODUCTS{Edge atsakymo cache šviežias?}
    EDGE_PRODUCTS -->|taip| PRODUCTS[Produktų sąrašas]
    EDGE_PRODUCTS -->|ne| VIEW[DB: catalog_items_read_with_lpl]
    VIEW --> PRODUCTS
    API_FACETS --> EDGE_FACETS{Edge facet cache šviežias?}
    EDGE_FACETS -->|taip| FACETS[Facetų atsakymas]
    EDGE_FACETS -->|ne| RPC[RPC catalog_facets_cached(filters)]
    RPC --> DB_CACHE{DB facet cache turi šį filtrą?}
    DB_CACHE -->|taip| FACETS
    DB_CACHE -->|ne| COMPUTE[Skaičiuoti facetus iš read modelių]
    COMPUTE --> DB_CACHE_WRITE[(Įrašyti catalog_facets_cache)]
    DB_CACHE_WRITE --> FACETS
    FACETS --> WEB_CACHE[Web atminties/localStorage cache: 5 min.]
    FACETS --> EDGE_WRITE[Edge cache atsakymas]
    WEB_CACHE --> UI[Produktai ir filtrai vartotojo ekrane]
    PRODUCTS --> UI
    FAIL_STALE[API klaidos atveju: gali būti grąžintas iki 24 h senumo Edge atsakymas] -.-> UI
  end

  SRC --> P1
  SRC --> P3
  SRC --> P4
  SRC --> P6
  P9 --> RPC
```

## Kaip skaityti schemą

- **Surinkimas ir read model refresh nėra tas pats darbas.** Cloudflare kas 15 min. paleidžia katalogo rinkimo workflow. Jis įrašo produktų partijas, o po darbo paprašo read modelio refresh. Metaduomenų workflow gali pateikti papildomą prašymą.
- **Kas 15 min. nereiškia, kad visas katalogas surenkamas iš naujo.** Workflow tęsia eilės darbus iki 10 min. biudžeto. Naujas target ciklas pradedamas tik kai ankstesnis nevyksta ir nuo paskutinės sėkmės praėjo 24 val.; nepavykę darbai kartojami po 5, 15 ir 60 min., vėliau gali būti užblokuoti. Taigi Cloudflare grafikas yra eilės darbuotojo pažadinimo dažnis.
- **Refresh prašymas nėra pilnas refresh.** Jis tik padidina `requested_version`. `pg_cron` periodiškai patikrina, ar yra neapdorotų versijų; prašymai sujungiami į vieną pilną perskaičiavimą. Jei nėra skirtumo, grąžinama `clean`.
- **Refresh fazės vyksta nuosekliai ir vienoje kontrolės grandinėje.** Dabartinis optimizuotas dydžių MV naudojamas kaip `catalog_size_facets_read` šaltinis. Viso refresh metu advisory lock saugo nuo antro lygiagretaus refresh.
- **Svetainės atsakymas turi kelis cache sluoksnius.** Web facet cache galioja 5 min.; API Edge cache taip pat laiko šviežią atsakymą 5 min. API klaidos atveju kodas gali grąžinti Edge atsakymą iki 24 h senumo. Todėl DB refresh grafikas vienas pats negarantuoja, kad kiekvienas vartotojas iškart pamatys naujus facetus.
- `apps/api/wrangler.jsonc` `*/5` grafikas vykdo Telegram alert apdorojimą. Katalogo rinkimo workflow iš ten paleidžiamas kas 15 min. Supabase `pg_cron` kas 5 min. yra atskiras jobas.

## 5 ar 10 minučių: ką tai pakeičia

| Pasirinkimas | Kas pasikeičia | Kas nepasikeičia |
| --- | --- | --- |
| `pg_cron` kas 5 min. | Pending refresh prašymai paimami dažniau; mažesnis laukimas iki darbo pradžios. | Nepagreitėja pats refresh; 5 min. timeout vis dar trumpesnis už paskutinį 5:24 vykdymą. |
| `pg_cron` kas 10 min. | Mažiau dažnų sunkių refresh patikrų/paleidimų ir daugiau laiko tarp ciklų. | Refresh vis dar trunka apie 5:24 pagal paskutinį matavimą; 5 min. timeout jį vis dar nutrauktų. |

Vien cron tarpas negarantuoja matomumo termino. Jei timeout leidžia refresh užbaigti, nuo prašymo iki DB užbaigimo teorinis laukimas gali apimti iki vieno grafiko intervalo ir visą refresh vykdymą: pagal dabartinį 5:24 matavimą tai būtų apie 10:24 su 5 min. grafiku arba 15:24 su 10 min. grafiku. Prie to prisideda laikas, kol katalogo sinchronizavimas pateikia prašymą. API Edge cache, browser cache ir klaidos atveju stale atsakymo grąžinimas gali vėlavimą padidinti; vartotojo matomumo terminą reikia matuoti atskirai, ne spręsti vien iš `pg_cron` grafiko.

Perėjimas nuo 5 iki 10 min. **nebūtinai sumažins sunkių MV atnaujinimų skaičių ar DB bloat**. Jei kiekvienas katalogo sync darbo paleidimas pakeičia produktus ir pateikia refresh prašymą, sunkus refresh gali vykti po kiekvieno tokio darbo ir su 10 min. tikrinimu. Tada sumažėtų daugiausia tušti `clean` patikrinimai; realių MV perrašymų skaičius gali likti panašus. Bloat mažinimui reikia matuoti, kiek realių refresh įvyksta per valandą, kiek pakeitimų jie sujungia ir kiek dead tuples susidaro po kiekvieno jų.

Vartotojo pateiktas paskutinis sėkmingas refresh užtruko **324 124 ms (5:24.124)**. Jis uždarė backlog'ą (`requested_version=completed_version=3239`), tačiau viršijo penkių minučių ribą. Tai buvo rankinis kontroliuotas catch-up su ilgesniu timeout, todėl šis rezultatas **neįrodo**, kad suplanuotas jobas su `statement_timeout='5min'` gali užbaigti darbą.

Repo radau 15 min. katalogo rinkimo grafiką ir 5 min. refresh grafiką, bet ne aiškų produkto SLA „pakeitimai privalo būti matomi per penkias minutes“. Prieš keičiant grafiką reikia sutarti priimtiną vėlavimą nuo šaltinio pakeitimo iki vartotojo ekrano. Tada reikia suderinti cron intervalą, timeout ir cache invalidavimą kaip vieną sprendimą.

## Pagrindiniai kodo taškai

- Cloudflare grafikai ir jų paskirtis: [`apps/api/wrangler.jsonc`](../../apps/api/wrangler.jsonc), [`apps/api/src/index.ts`](../../apps/api/src/index.ts).
- Katalogo workflow: [`.github/workflows/sync-catalog.yml`](../../.github/workflows/sync-catalog.yml), [`apps/sync/src/catalog-queue.ts`](../../apps/sync/src/catalog-queue.ts).
- Eilės target ciklų, lease ir pakartojimų taisyklės: [`20260921122000_add_catalog_collection_queue.sql`](../../supabase/migrations/20260921122000_add_catalog_collection_queue.sql).
- Refresh prašymo ir cron funkcijų bazė: [`20260714205054_stabilize_catalog_refresh.sql`](../../supabase/migrations/20260714205054_stabilize_catalog_refresh.sql).
- Dabartinės fazės ir jų žurnalavimas: [`20261007200200_instrument_catalog_refresh_phase_timings.sql`](../../supabase/migrations/20261007200200_instrument_catalog_refresh_phase_timings.sql).
- Web facet cache: [`apps/web/pages/index.vue`](../../apps/web/pages/index.vue), [`apps/web/utils/catalogFacetRequest.ts`](../../apps/web/utils/catalogFacetRequest.ts).
- Išsami istorija ir faktiniai matavimai: [`CRON_REFRESH_CHRONOLOGINE_ANALIZE_2026-10-11.md`](CRON_REFRESH_CHRONOLOGINE_ANALIZE_2026-10-11.md).
