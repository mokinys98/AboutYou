# Katalogo filtravimo VPS analizė (2026-10-04)

## Išvada

`canceling statement due to statement timeout` kyla pirmiausia iš **filtrų reikšmių (facetų) perskaičiavimo po cache miss**, o ne iš pirmojo produktų puslapio. VPS `authenticator` rolėje yra `statement_timeout=8s`. Tiriant realius VPS duomenis, „mažiau nei LPL + juoda“ filtro ne dydžių facetų SQL truko **3,83 s**, o dydžių facetų SQL **6,23 s**. Jie `catalog_facets_cached()` vykdomi nuosekliai, taigi vien skaitančios dalys kartu reikalauja apie **10,1 s**. Vien juodos spalvos atveju atitinkamai **4,63 s + 5,92 s = 10,55 s**. Tikslus RPC laikas gali skirtis dėl cache, apkrovos ir disko būklės, tačiau šios trukmės paaiškina 8 s timeout.

OpenSearch šiuo metu nėra pagrįstas kaip pirmas sprendimas. Planuose matomi taisytini PostgreSQL užklausų ir read modelio trūkumai.

## Metodas ir ribos

- Naudotas naudotojo leistas `127.0.0.1:15432` tunelis ir `codex_reader` paskyra. Kiekviena sesija pradėta `BEGIN READ ONLY`, baigta `ROLLBACK`; duomenys VPS nekeisti.
- Parametrai atitinka API siunčiamą `p_filters`: `{"belowObserved30d":true,"priceComparison":"source_lpl","colorShades":["black"]}` ir atskirai `{"colorShades":["black"]}`. Produkto kelias naudoja `below_source_lpl_30d=true` bei `color_shade='black'`.
- `catalog_facets_cached()` negalima vykdyti read-only režimu, nes cache miss metu ji daro `INSERT`. `codex_reader` taip pat neturi `EXECUTE` teisių vidinėms `catalog_facets()` funkcijoms. Todėl `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` paleistas **gyvai VPS esančių skaitančių funkcijų SQL kūnams** su tais pačiais parametrais. Neaktyvių `excludeBasics` ir `excludeAccessories` pagalbinių funkcijų išraiškos pakeistos tuščiais masyvais; `catalog_simple_facet()` apvalkalas pakeistas `to_jsonb()` vien tam, kad skaitantis SQL būtų leidžiamas `codex_reader`. Facetų skaičiavimo CTE, lentelių jungimai ir filtrų predikatai liko tie patys. Tai detalių planų matavimas, o ne tiesioginis viso RPC matavimas.
- Produktų puslapio ir tikslaus `count(*)` SQL taip pat vykdyti su `EXPLAIN ANALYZE`. Tyrimo momentu `catalog_items_read` turėjo 98 737 eilutes, `catalog_item_facet_values_read` apie 2,1 mln., `catalog_size_facets_read` apie 363 tūkst. `catalog_facets_cache` turėjo **0** įrašų.

## Išmatuoti planai

| Užklausa | Vykdymas | Pagrindinis planas |
| --- | ---: | --- |
| Produktų puslapis, „< LPL“ | 155 ms | `catalog_items_read_updated_idx`, 49 eilutės |
| Produktų puslapis, „< LPL + juoda“ | 187 ms | tas pats indeksas, 49 eilutės |
| Tikslus produktų kiekis, „< LPL + juoda“ | 601 ms | `catalog_items_read_color_shade_idx`, 4 300 tinkančių eilučių |
| Kiti facetai, „< LPL + juoda“ | 3 826 ms | pilnas 98 737 produktų ir 2 107 319 facetų reikšmių skenavimas; hash join; 124 384 eilutės prieš grupavimą; rūšiavimas diske (4 424 kB) |
| Dydžių facetai, „< LPL + juoda“ | 6 226 ms | 94 437 produktai atmesti, tačiau prieš prijungiant 4 300 tinkamų produktų perskaitomos visos 362 769 dydžių eilutės ir apdorojami override |
| Kiti facetai, tik juoda | 4 627 ms | pilnas produktų ir apie 2,1 mln. facetų reikšmių skenavimas |
| Dydžių facetai, tik juoda | 5 919 ms | 80 632 produktai atmesti, bet vis tiek perskaitomos apie 363 tūkst. dydžių eilučių |

Žali `EXPLAIN ANALYZE` JSON planai: [kiti facetai, LPL + juoda](catalog_facets_lpl_black_explain_2026-10-04.json), [dydžiai, LPL + juoda](catalog_sizes_lpl_black_explain_2026-10-04.json), [kiti facetai, juoda](catalog_facets_black_explain_2026-10-04.json), [dydžiai, juoda](catalog_sizes_black_explain_2026-10-04.json).

Papildomas diagnostinis bandymas `enable_hashjoin=off` su „< LPL + juoda“ dydžių SQL pasiekė net 55 s timeout. Jo naudoti kaip optimizacijos negalima.

## Kas konkrečiai blogai

1. **Ne dydžių facetai išplečia darbą iki viso katalogo.** `catalog_facets()` sudaro `checks` ir `base` iš visų 98 737 produktų, tada jungia su visais ~2,1 mln. `catalog_item_facet_values_read` įrašų. „< LPL“ sąlyga yra `common_ok`, tačiau ji pritaikoma tik po šio jungimo per `failed_groups`. Kadangi bendro filtro nė vienas facetas negali ignoruoti, jį saugu pritaikyti prieš 2,1 mln. eilučių jungimą. Turimas `(product_id, facet_group, value)` indeksas nepadeda, kai planas vis tiek skaito visą facetų lentelę. 4 MB `work_mem` sąlygomis rūšiavimas išsilieja į diską.
2. **Dydžių facetai kas kartą konstruoja „effective“ dydžių vaizdą.** `catalog_size_facets_read_effective` yra paprastas view virš `catalog_size_facets_read`, klasifikacijos override ir dydžių normalizavimo funkcijų. Planas apdoroja visas ~363 tūkst. dydžių eilučių prieš sumažinimą iki 12 514 produkto ir dydžio porų pasirinktame „< LPL + juoda“ kontekste. Tai kainuoja daug daugiau nei pats 98 tūkst. produktų filtras (~185 ms). `catalog_size_facets_read` jau turi `(product_id, token)` indeksą, taigi problema yra jungimo tvarka bei dinaminio vaizdo skaičiavimas, o ne vien indekso nebuvimas.
3. **Cache miss yra brangus ir šio matavimo metu cache buvo tuščias.** `catalog_facets_cached()` pirmiausia skaičiuoja `catalog_facets()`, paskui `catalog_grouped_size_facets()`, tuomet įrašo rezultatą. Naujų kombinacijų skaičius didelis. Naršyklės maršruto stebėtojas iškviečia `loadFacets(..., { force: true })`, todėl keičiant filtrą apeinamas vietinis 5 min. cache. Jei RPC nepavyksta, `loadFacets()` klaidą paverčia `null`; kai naujam kontekstui nėra galiojančio vietinio įrašo, ankstesni facetai jau būna išvalyti ir „Dydis“ UI lieka be reikšmių.
4. **Pasirinkto grupuoto dydžio semantika skiriasi tarp produktų ir kitų facetų.** Produktų API grupuotus tokenus filtruoja per `size_tokens`, tačiau VPS `catalog_facets()` tikrina `i.sizes && f.sizes` prieš žalių dydžių masyvą. Pvz., `shoes:42` ir žalias `42` nesutampa, tad po dydžio pasirinkimo kitų facetų kiekiai gali tapti klaidingai nuliniai arba išnykti. Dydžių facetas savo dydžio filtrą sąmoningai ignoruoja, bet kiti facetai jo nepaiso neteisingai.
5. **`lplProximityPct` skirtingai taikomas facetams.** Kontekstinis dydžių builderis tikrina `lpl_price_ratio`, o VPS `catalog_facets()` šio parametro visai neskaito. Dėl to pasirinkus „arti LPL“ dydžių ir kitų facetų kiekiai gali atspindėti skirtingus produktų rinkinius.
6. **`otherSizes` visada priverstinai grąžinamas kaip `[]`.** Tai atskiras senesniame plane aprašytas korektiškumo trūkumas; papildomi dydžiai UI gali dingti, net jei produktas juos turi.

## Rekomenduojamas taisymo eiliškumas

1. **Ištaisykite skaičiavimo kelią.** `catalog_facets()` bendrus predikatus (`belowObserved30d` su `priceComparison`, `newOnly`, `discountMin`, ir `lplProximityPct`) taikykite prieš jungimą su facetų reikšmėmis. Savęs ignoravimo logiką palikite tik pačios facetų grupės filtrui. Pasirinktų filtrų predikatus generuokite taip, kad PostgreSQL galėtų naudoti indeksus, užuot vertinęs `cardinality(...) = 0 OR ...` kiekvienai eilutei.
2. **Suvienodinkite dydžių narystę.** Ne dydžių facetai ir produktų sąrašas turi remtis tais pačiais grupuotais `size_tokens` bei legacy dydžių predikatais. `otherSizes` rezultatą atkurkite pagal realią prekių narystę. Pridėkite `lplProximityPct` prie visų facetų bendro filtro.
3. **Materializuokite effective dydžių narystę arba atnaujinkite ją prie katalogo refresh.** Rekomenduojamas indeksas pagal `(product_id, token)` ir atskiras indeksas, jei reikia, pagal `(token, product_id)`. Override pakeitimas turi invaliuoti / atnaujinti šį read modelį. Tikslas: kontekstinį dydžių count skaičiuoti nuo tinkamų produktų ID, o ne kiekvieną kartą plėsti visus dydžius.
4. **Sutvarkykite cache ir UI.** Atskirai cache'inti skirtingas facetų dalis arba taikyti nuoseklų katalogo versijos raktą; vengti pilno cache išvalymo po kiekvieno smulkaus atnaujinimo. Maršruto pasikeitimo metu naudoti galiojantį vietinį cache, o klaidos atveju parodyti aiškią facetų įkėlimo klaidą ir išsaugoti paskutinį tinkamą sąrašą.
5. **Tikrinti po pakeitimų.** Pakartoti tuos pačius keturis `EXPLAIN (ANALYZE, BUFFERS)` scenarijus, palyginti su čia išsaugotais planais, patikrinti tikslius count bei dydžių tokenus po „< LPL“, spalvos ir jų kombinacijos. Tikslas: cache miss turi tilpti gerokai žemiau 8 s (geriau <1–2 s), p95 matuojant realiu API keliu. Vien timeout didinimas tik paslėptų brangią užklausą.

## Ką galima perimti iš didelių katalogų neplečiant infrastruktūros

Vieši Zalando inžinierių aprašymai rodo, kad produktų paieška ir facetų agregacijos yra atskiri apkrovos tipai: jų Catalog API filtrų reikšmes gauna atskiru kreipiniu, o dažniems filtrų deriniams naudoja cache. Net jų Elasticsearch klasteryje pernelyg plačios facetų agregacijos buvo sukėlusios sulėtėjimą, tad vien paieškos variklio pakeitimas brangios užklausos nepanaikina ([Zalando incidento analizė, 2025](https://engineering.zalando.com/posts/2025/12/we-hacked-ourselves-so-you-dont-have-to.html)). Ankstesniame architektūros aprašyme jie taip pat skiria iš anksto apibrėžtą kategorijų struktūrą nuo pagal aktyvius filtrus skaičiuojamų facetų ([Zalando paieškos architektūra, 2017](https://engineering.zalando.com/posts/2017/02/using-microservices-to-power-fashion-search-and-discovery.html)).

ABOUT YOU / SCAYLE vieša dokumentacija aprašo atskirą produktų ir filtrų API bei reikalauja jiems perduoti tą patį filtravimo kontekstą, kad produktų ir facetų kiekiai sutaptų ([SCAYLE produktų ir filtrų naudojimas](https://scayle.dev/documentation/the-basics/products/using-products-in-your-store), [SCAYLE filtrai](https://scayle.dev/documentation/the-basics/shops/filters)). Šie šaltiniai neatskleidžia ABOUT YOU vidinės duomenų bazių infrastruktūros, todėl jų negalima laikyti argumentu kopijuoti konkretų paieškos variklį.

**Šiam projektui tinkantis variantas:** palikti esamą VPS PostgreSQL ir joje optimizuoti skaitančias užklausas. Produktų puslapio kelias jau trunka apie 0,2 s; reikia panaikinti viso katalogo facetų ir dydžių narystės perskaičiavimą kiekvienam naujam deriniui. Kategorijų medį bei normalizuotą produkto–dydžio narystę paruošti esamo katalogo atnaujinimo metu, o dinamiškus kiekius skaičiuoti nuo pirma atrinktų produktų ID. Produktams ir facetams naudoti vienodus predikatus, atskirai cache'inti dažnus kontekstus ir neleisti UI ištuštėti dėl vienos facetų užklausos klaidos. Tai atitinka aukščiau nurodytą taisymo eiliškumą ir nereikalauja naujos paslaugos ar VPS plano.

Šis kelias nėra nemokamas resursų prasme: papildomas read modelis naudos dalį esamo disko, jo atnaujinimas – CPU, o įgyvendinimas – kūrimo laiką. Prieš priimant sprendimą dėl OpenSearch reikia pamatuoti naują cache miss trukmę ir p95 realiu API keliu, patikrinti count tikslumą ir stebėti VPS resursus per katalogo atnaujinimą. Jei po šių pataisų tikslai vis tiek nepasiekiami, tada lyginti atskiro paieškos variklio naudą su jo infrastruktūros ir priežiūros kaina.

Šiame tyrime VPS migracija netaikyta. Jei bus rengiamas SQL pakeitimas, jis turi būti atskira migracija `supabase/migrations/`, kurią naudotojas pritaiko per Supabase SQL Editor pagal repo taisykles.
