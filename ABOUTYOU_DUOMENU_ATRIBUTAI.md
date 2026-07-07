# ABOUT YOU prekių gavimo ir atributų analizė

Analizės data: 2026-07-06.

## Trumpa išvada

Dabartinis sinchronizatorius prekes renka pirmiausia iš ABOUT YOU katalogo vidinio `CategoryStreamService` produkto srauto. Jei tiesioginis srautas nepavyksta, naudojama puslapio pradinė būsena ir katalogo kortelių DOM slinkimo alternatyva.

Produkto detalės tikrinamos atskiru valandiniu jobu. Iš produkto HTML `data-tadarida-initial-state` paimamas tik `ArticleDetailService/GetProductBulk` atsakymas, o kiekvienam produktui DB laikoma viena naujausia sanitizuota raw JSON kopija. Dydis ir forma, išmatavimai, medžiagų sudėtis, dizainas, spalvų variantai ir dydžių prieinamumas saugomi atskirame autoritetingame modelyje; fallback reikšmės į jį nepatenka.

## Kaip dabar gaunamos prekės

1. `apps/sync/src/index.ts` paima aktyvius `sync_targets` įrašus. Leidžiami tik `https://aboutyou.lt` ir jo subdomenų URL.
2. Playwright atidaro tikslinį kategorijos, prekės ženklo arba paieškos URL ir į puslapį įkelia `aboutyou-price-sort.user.js` kolektorių.
3. Pagrindinis kelias kreipiasi į gRPC-web srautą:
   `aysa_api.services.category_page.v1.stream.CategoryStreamService/GetProductStreamV2`, o kitus puslapius gauna per `GetProductStreamPageV2`.
4. Iš kiekvieno `productTile` rekursyviai ieškomi žemiau lentelėje nurodyti laukai.
5. Jei tiesioginis srautas neveikia, skaitomi `script[data-tadarida-initial-state="true"]` duomenys ir slenkamas katalogo DOM. Grynas DOM fallback patikimai gauna tik ID, URL, pavadinimą ir dabartinę kainą; kiti laukai dažniausiai lieka tušti arba perimami iš pradinės būsenos.
6. Anksčiau DB išsaugota spalva atkuriama, jei naujame katalogo atsakyme jos nėra.
7. Atskiras `sync:metadata` jobas atominiu `SKIP LOCKED` claim ima tik neapdorotus einamos parserio versijos produktus arba dydžių prieinamumą, kurio 24 val. terminas pasibaigė.
8. Kategorijos papildomos target pavadinimu ir plačiomis kategorijomis, nuspėtomis iš produkto pavadinimo.
9. Produktai po 200 įrašomi per `record_catalog_batch`; kainos kartu įrašomos į dabartinį pasiūlymą, dienos kainų suvestinę ir tikslaus laiko pokyčių istoriją.

Tuščias arba nepilnas rinkimas sėkmingu nelaikomas. Taip tuščias scrape nepadidina dingimo skaitiklių ir neišjungia viso katalogo.

## Katalogo puslapyje matomi duomenys

2026-07-05 patikrinus viešą [vyriškų drabužių katalogą](https://www.aboutyou.lt/c/vyrams/drabuziai-20290), puslapyje matoma:

| Grupė | Matomi atributai | Ar dabartinis sync gauna? |
|---|---|---|
| Katalogo kontekstas | breadcrumb/kategorija, puslapio pavadinimas, bendras rezultatų skaičius | Rezultatų skaičius gaunamas kaip `expectedTotal`; kategorija imama iš tile, o jai nesant – iš produkto JSON-LD breadcrumb. Target ir pavadinimo heuristika naudojami tik kaip fallback. |
| Filtrai | kaina, išpardavimas, dydis, spalva, prekės ženklas, kiti dydžiai, medžiaga, raštas, prekės savybės | Schema šiuos produkto atributus numato, bet kolektorius juos gauna tik tada, jei atitinkami laukai yra `productTile`. Pačių filtro reikšmių ar jų ID jis nerenka. |
| Kategorijai specifiniai filtrai | pvz. `Style`, sporto šaka, funkcijos, iškirptė, rankovių ilgis, pakuotė | Tik bendras `styles` ir `features` paieškos bandymas; sporto šaka, funkcijos, iškirptė, rankovės ir pakuotė atskirai neišsaugomi. |
| Kortelės tapatybė | produkto ID, URL, prekės ženklas, produkto tipo/pavadinimo tekstas, modelio pavadinimas | Taip, tačiau tipas ir modelis saugomi bendrame `name`; struktūruotų atskirų laukų nėra. |
| Kortelės kainos | dabartinė kaina, kaina „nuo“, pradinė kaina, paskutinė mažiausia kaina, nuolaidos procentas | Dabartinė, pradinė ir LPL bandomos gauti. Kaina „nuo“ ir kainos pagal konkretų dydį/variantą neišskiriamos. Nuolaida DB/API apskaičiuojama iš dabartinės ir pradinės kainos. |
| Kortelės vaizdai | pagrindinė nuotrauka | Taip. Rekursyviai surenkama iki 6 paveikslėlių URL, bet tai nebūtinai 6 skirtingi produkto vaizdai – gali būti to paties vaizdo dydžių variantai. |
| Pasirinkimai | galimi dydžiai, „yra daugybė dydžių“, papildomų spalvų skaičius `+N` | `sizes` bandomi gauti iš tile laukų. Bendrinis prieinamumo tekstas ir `+N` spalvų variantai neišsaugomi. |
| Žymos | `Premium`, `PASIŪLYMAS`, `KUPONAS`, `IŠPARDAVIMAS`, `Naujiena`, `Išskirtinė prekė`, `Uniseksas`, `N vnt. pakuotė` | Ne. Atskirų laukų nėra. Dalis teksto gali netyčia patekti į DOM fallback pavadinimą, bet tai nėra patikimas struktūruotas gavimas. |
| Siluetas / prigludimas | pvz. `Standartinis`, `Laisvas`, `Siaurėjantis`, `Prigludęs` | Gali patekti į `name`, `styles` arba `features`, jei taip pateikta tile, bet atskiro garantuoto lauko nėra. |
| Pirkimo veiksmas | „Į krepšelį“ ir bendras prekės prieinamumas | Ne. Atsargų kiekis ir variantų prieinamumas nesaugomi. |

### Tikslūs iš katalogo srauto ieškomi laukai

| Mūsų laukas | ABOUT YOU tile reikšmės / paieškos raktai | Tipas ir apdorojimas | Patikimumas |
|---|---|---|---|
| `externalId` | `productId`; DOM fallback – skaičius URL gale | `string`, privalomas | Aukštas |
| `productUrl` | `link.url`, `productTracker.linkTarget`; DOM `<a href*="/p/">` | Absoliutus HTTPS URL, privalomas | Aukštas |
| `name` | `productTracker.productName`; DOM paveikslėlio `alt`, `aria-label` ar kortelės tekstas | `string`, privalomas; fallback gali būti netikslus | Aukštas sraute, vidutinis DOM fallback |
| `brand` | `brandName`, `brandTracker.name` | `string`, gali būti tuščias | Aukštas sraute, žemas DOM fallback |
| `imageUrls` | visi tile viduje rasti HTTPS `.jpg`, `.jpeg`, `.webp`, `.avif` URL | unikalizuojama, daugiausia 6 | Vidutinis |
| `colorOriginal` | rekursyviai: `colorLabel`, `colorName`, `color`, `displayColor`, `baseColor` | originalus tekstas arba `null` | Vidutinis; jei trūksta, tikrinamas detalės puslapis |
| `colorFamily` | ne ABOUT YOU laukas | iš `colorOriginal` normalizuojama į 16 plačių spalvų | Išvestinis |
| `colorShade` | ne ABOUT YOU laukas | iš `colorOriginal` normalizuojama į 35 atspalvius | Išvestinis |
| `categories` | `category`, `categoryName`, `categoryNames`, `categories`; produkto JSON-LD `BreadcrumbList` | iki 30 tile tekstų arba sutvarkytas breadcrumb kelias; lapinė kategorija išplečiama iki kairiojo meniu tėvinės struktūros | Aukštas, kai yra šaltinio kategorija; kitu atveju naudojamas fallback |
| `sizes` | `availableSizes`, `sizeLabels`, `sizes` | iki 30 tekstų | Nežinomas/vidutinis; priklauso nuo tile struktūros |
| `otherSizes` | `otherSizes`, `specialSizes`, `sizeGroups` | iki 30 tekstų | Nežinomas/vidutinis |
| `materials` | `material`, `materials`, `materialName`, `materialComposition` | iki 30 tekstų | Žemas; katalogo tile dažnai neturi pilnos sudėties |
| `patterns` | `pattern`, `patterns`, `patternName` | iki 30 tekstų | Nežinomas/vidutinis |
| `features` | `features`, `productFeatures`, `attributes` | iki 30 tekstų | Žemas; bendras `attributes` gali sumaišyti skirtingas savybes |
| `styles` | `style`, `styles`, `styleName` | iki 30 tekstų | Nežinomas/vidutinis |
| `productTypes` | `productType`, `productTypes`, `productTypeName`; jei nerasta – tekstas iki modelio kabutėse | iki 30 tekstų | Vidutinis; fallback yra heuristika |
| `currentPrice` | `price.price.amount`, `tracker.price`, `priceV2.finalPrice.priceLabel.text`; DOM kortelės kainų tekstas | sveikas skaičius euro centais, privalomas | Aukštas sraute, vidutinis DOM fallback |
| `originalPrice` | `tracker.fullPrice`, `priceV2.original.text`; DOM `Pradinė kaina` | euro centai arba `null` | Aukštas sraute, vidutinis DOM fallback |
| `sourceLpl30` | `priceV2.lpl30d.value.text`, `price.lpl30`; DOM `Paskutinė mažiausia kaina` | euro centai arba pagal schemą `null` | Šiuo metu turi kritinę semantikos problemą, aprašytą žemiau |
| `currency` | kode fiksuota reikšmė | visada `EUR` | Ne scraped |

`findStrings` priima tekstą arba objekto `label`, `name`, `value`, `text`, atmeta URL ir ilgesnius nei 100 simbolių tekstus, unikalizuoja ir palieka daugiausia 30 reikšmių. Tai lankstu keičiantis ABOUT YOU schemai, bet gali paimti semantiškai ne tą to paties pavadinimo giluminį lauką.

## Produkto puslapyje matomi duomenys

Viešame pavyzdyje [UNDER ARMOUR sportiniai marškinėliai, produkto ID 3935028](https://www.aboutyou.lt/p/under-armour/sportiniai-marskineliai-3935028) matomi šie atributai:

| Grupė | Produkto puslapyje matoma | Ką dabar pasiima sync |
|---|---|---|
| Tapatybė | breadcrumb kategorijų kelias, prekės ženklas, pilnas pavadinimas, produkto URL | Kategorijos imamos iš `GetProductBulk.linksSection.breadcrumbs`; JSON-LD lieka fallback. |
| Nuotraukos | keli vaizdai, pvz. priekis, galas ir papildomi kadrai; `alt` aprašai | `GetProductBulk.imagesSection.images` URL atnaujina `image_urls`. |
| Kaina | dabartinė kaina, valiuta, PVM tekstas, galimos akcijų ir ankstesnės kainos | Nerenkama iš detalės; naudojama katalogo kaina. |
| Spalva | pasirinkta spalva ir galimi spalvos variantai | `productSelectionSection` variantų ID, URL, spalvos tekstas ir pasirinkimo būsena saugomi `product_color_options`. |
| Dydžiai | dydžių pasirinkimai ir dydžių lentelė | Šaltinio dydžio ID, etiketė, grupė ir pasirinkimo būsena saugomi `product_size_options`. |
| Prieinamumas | ar konkretus dydis pasirenkamas, pristatymo laiko įvertinimas | `availability.$case` saugomas be interpretavimo; `inStock` žymimas pasirenkamu, `soldOut` – nepasirenkamu. |
| Pristatymas ir grąžinimas | pristatymo kaina/laikas, 30 dienų grąžinimo teisė | Ne |
| Dizainas ir priedai | pvz. vienspalvis, plonas trikotažas, apskrita kaklo iškirptė, to paties tono siūlės, minkšta tekstūra, spausdinta etiketė | Detalės `bulletPointLane` ir `regularLane` reikšmės įrašomos į `features`. |
| ABOUT YOU prekės numeris | pvz. `UNA0359001000006` | Ne. Dabartinis `externalId` yra katalogo skaitinis `productId`, o ne šis prekės numeris. |
| Dydis ir forma | rankovių ilgis, gaminio ilgis, prigludimas | Saugoma `product_detail_sections` kaip lossless label/value poros. |
| Išmatavimai | galinės dalies plotis, bendras ilgis, rankovių ilgis ir matavimo dydis | Skaitinės `sizeLane` reikšmės atskiriamos į `measurements`, išlaikant originalų tekstą ir matavimo vienetą. |
| Medžiagų sudėtis | pvz. `60% Medvilnė, 40% Poliesteris – PES` | `materialLane` saugomas `material_composition` sekcijoje ir išvedamas į `materials`. |
| Priežiūra | skalbimo temperatūra, cheminis valymas, lyginimas, balinimas, džiovinimas | Ne |
| Gamintojas | juridinis pavadinimas, adresas, šalis, el. paštas | Ne |
| Funkcionalumas | funkcinių savybių skiltis, jei produktui taikoma | Ne |
| Kiti UI duomenys | teisinės problemos pranešimas, Coins pasiūlymas | Ne; tai nėra produkto katalogo atributai. |

### Kaip gaunama produkto detalė

Produkto HTML tikrinamas tokia tvarka:

1. `script[data-tadarida-initial-state="true"]` įraše ieškomas raktas, prasidedantis `aysa_api.services.article_detail_page.v1.ArticleDetailService/GetProductBulk`;
2. saugomas tik `payload.data`, prieš tai pašalinus transporto `trailers` su A/B testų žymomis;
3. baziniai laukai imami iš konkrečių `imagesSection`, `sizesSection`, `productDetailsSection` ir `linksSection` kelių;
4. payload neradus, spalvai, kategorijai ir bendriems atributams naudojamas ankstesnis JSON-LD parseris.

Nesaugomas visas HTML, request antraštės, slapukai, kampanijų, navigacijos ar page-meta initial-state atsakymai.

## Kas išsaugoma duomenų bazėje

### Tiesiogiai gauti produkto duomenys

`products` lentelėje saugoma:

- `source_id`, `external_id`, `name`, `brand`;
- `product_url`, `image_urls`;
- `color_original`, normalizuoti `color_family` ir `color_shade`;
- `sizes`, `other_sizes`, `materials`, `patterns`, `features`, `styles`, `product_types`;
- `active`, `first_seen_at`, `last_seen_at`, `updated_at`;
- paskutinio detalės bandymo `detail_checked_at` ir trumpas `detail_last_error` kodas.

`product_detail_raw` lentelėje saugoma viena naujausia kopija produktui:

- `payload`, deterministinis SHA-256 `payload_hash`;
- sėkmingo gavimo `fetched_at`, `source_endpoint` ir `parser_version`;
- payload neindeksuojamas GIN ir nėra pasiekiamas `anon` ar `authenticated` rolėms;
- jei hash nepasikeitė, JSON neperrašomas; istorinių kopijų nekuriama.

Faktiniam dydžiui PostgreSQL patikrinti:

```sql
select
  count(*) as products_with_raw,
  pg_size_pretty(sum(pg_column_size(payload))) as payload_size,
  pg_size_pretty(pg_total_relation_size('public.product_detail_raw')) as table_with_indexes
from public.product_detail_raw;
```

`offers` lentelėje saugoma:

- `current_price`, `original_price`, `source_lpl_30`, `currency`;
- sistemos apskaičiuotas `observed_min_30d`;
- `updated_at`.

`daily_prices` lentelėje kiekvienai dienai saugoma:

- mažiausia, didžiausia ir paskutinė tą dieną stebėta kaina;
- ABOUT YOU LPL reikšmė;
- stebėjimų skaičius ir atnaujinimo laikas.

`price_changes` lentelėje saugomas kiekvienas pastebėtas dabartinės kainos pasikeitimas:

- tiksli stebėjimo data ir laikas;
- nauja dabartinė ir tuo metu gautos pradinė bei ABOUT YOU LPL kainos;
- nepakitusi kaina pakartotinio sinchronizavimo metu nėra dubliuojama.

### Priskirti arba apskaičiuoti, o ne gauti iš ABOUT YOU

| Laukas | Kilmė |
|---|---|
| `colorFamily` | Normalizuojamas iš originalaus spalvos teksto. |
| `colorShade` | Normalizuojamas iš originalaus spalvos teksto; DB triggeris perskaičiuoja jį keičiantis `color_original`. |
| `categories` | Target pavadinimas, galimi tile duomenys fallback kelyje ir heuristika pagal produkto pavadinimą. |
| `productTypes` fallback | Produkto pavadinimo dalis iki modelio kabutėse. |
| `observedMin30d` | Mūsų pačių per paskutines 30 dienų stebėtų dienos minimumų minimumas. |
| `discountPct` | `(originalPrice - currentPrice) / originalPrice`. |
| `belowObserved30d` | Ar dabartinė kaina ne didesnė už mūsų 30 dienų minimumą. |
| `belowSourceLpl30d` | Ar dabartinė kaina ne didesnė už ABOUT YOU LPL; jai nesant naudojamas mūsų minimumas. |
| `source` | Vidinis šaltinio slug, dabar `aboutyou-lt`. |
| `isWatched` | Prisijungusio naudotojo stebėjimo būsena. |

## Svarbios dabartinės spragos ir rizikos

1. **`sourceLpl30` gali būti klaidingas.** `aboutyou-price-sort.user.js` funkcija `normalizeLplPrice` nerastą LPL pakeičia dabartine kaina (arba `0`). Provideris vėliau `lplIsFallback` požymio nepatikrina ir šią reikšmę įrašo kaip tikrą `sourceLpl30`. Vadinasi, daliai prekių „ABOUT YOU LPL“ iš tiesų gali būti dabartinė kaina. Kol tai nepataisyta, šio lauko negalima laikyti audituojamai tiksliu.
2. **Schemos laukas nereiškia, kad duomenų yra.** Dalis laukų gaunama iš konkrečių produkto API sekcijų, bet `patterns` ir kai kurios kategorijai specifinės reikšmės vis dar priklauso nuo JSON-LD arba katalogo duomenų. Užpildymo procentas nematuojamas.
3. **Dalis payload lieka tik raw.** Priežiūros piktogramos, gamintojo kontaktai, dydžių lentelių kūno išmatavimai ir prekės numeriai dar nėra viešo API kontrakto dalis.
4. **Ne kiekviena prekė būtinai turi šaltinio kategoriją.** Kai jos nėra nei tile, nei per ribojamą detalės praturtinimą, lieka target ir pavadinimo regex fallback. Šaltinio kategorijai atsiradus, seni klaidingi produkto kategorijų ryšiai pakeičiami autoritetingu keliu.
5. **Variantų kainos ir SKU dar nepilni.** Spalvų bei dydžių ID, URL ir prieinamumas sumodeliuoti, tačiau atskiros dydžio kainos, kiekiai ir `articleNumber` dar negrąžinami produkto API.
6. **DOM fallback yra informacijos prasme skurdus.** Jis skirtas neprarasti viso rinkimo, bet iš DOM patikimai ištraukia gerokai mažiau atributų nei srauto kelias.
7. **Paveikslėlių semantika nežinoma.** Saugomi URL be vaizdo tipo, pozicijos, pločio, aukščio ar spalvos varianto ryšio.
8. **Kaina „nuo“ ir konkretaus dydžio kaina neišskiriama.** Išsaugoma viena kortelės kaina, todėl variantų kainų diapazonas gali būti prarastas.

## Rekomenduojama pilno detalės rinkimo struktūra

Jei tikslas yra turėti visus produkto puslapyje matomus atributus, verta pridėti atskirą detalės modelį ir rinkti bent:

- `articleNumber` / ABOUT YOU prekės numerį;
- originalų breadcrumb ir kategorijų ID/tekstą;
- struktūruotas `designAttributes` ir `fitAttributes` poras;
- `materialComposition` su komponentu ir procentu;
- `careInstructions`;
- matmenis kartu su matavimo dydžiu;
- `manufacturer` pavadinimą ir kontaktus;
- spalvos variantus su atskirais produkto ID/URL;
- dydžio variantus, jų prieinamumą ir kainą;
- paveikslėlius su pozicija, tipu ir varianto ryšiu;
- aiškų `badges`, `gender`, `packSize`, `fit`, `sport`, `functions`, `neckline`, `sleeveLength` modelį.

Detalės rinkimas turėtų būti atskiras, ribojamas ir kešuojamas etapas, nes užklausti kiekvieną iš dešimčių tūkstančių produkto puslapių per kiekvieną katalogo sync būtų lėta ir didintų 403/429 blokavimo riziką.

## Analizei naudoti vietiniai failai

- `packages/aboutyou-provider/src/index.ts` – katalogo ir spalvos rinkimo adapteris;
- `aboutyou-price-sort.user.js` – tiesioginio srauto bei DOM kolektorius;
- `apps/sync/src/index.ts` – sync eiga, kategorijų papildymas ir saugojimas;
- `packages/shared/src/index.ts` – produkto ir API schemos, spalvų normalizavimas;
- `supabase/migrations/202607050001_initial_catalog.sql` – bazinis produktų, pasiūlymų ir kainų istorijos modelis;
- `supabase/migrations/202607050002_product_attributes.sql` – papildomi produkto atributai ir `record_catalog_batch`;
- `supabase/migrations/202607050003_catalog_filters_watchlist.sql` – spalvos atspalvis, katalogo view ir stebėjimas;
- `supabase/migrations/202607050006_protect_catalog_from_empty_sync.sql` – apsauga nuo tuščio rinkimo.
