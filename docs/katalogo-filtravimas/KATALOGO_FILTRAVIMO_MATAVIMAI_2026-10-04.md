# Katalogo filtravimo matavimai po facetų optimizavimo (2026-10-04)

## Santrauka

VPS `catalog_facets()` funkcijoje patvirtinta, kad bendras `common_ok` filtras vykdomas prieš jungiant facetų reikšmes. Pakartotiniai SQL planai rodo aiškų pagreitėjimą „žemiau LPL + juoda“ scenarijuje. Vien „juoda“ filtro scenarijus nepagerėjo, todėl bendras cache miss laikas šiam kontekstui tebėra virš 8 s tikslo.

| Scenarijus | Bazinis planas | Pakartojimas A | Sekamas planas B | Pokytis B prieš bazę |
| --- | ---: | ---: | ---: | ---: |
| Ne dydžių facetai: juoda | 4 626,608 ms | 4 482,002 ms | 4 944,411 ms | +317,803 ms |
| Dydžių facetai: juoda | 5 918,795 ms | 6 070,872 ms | 5 970,691 ms | +51,896 ms |
| Ne dydžių facetai: žemiau LPL + juoda | 3 825,775 ms | 1 620,858 ms | 1 797,183 ms | −2 028,592 ms |
| Dydžių facetai: žemiau LPL + juoda | 6 225,664 ms | 5 551,162 ms | 5 093,993 ms | −1 131,671 ms |

Nuosekliai vykdomų dviejų SQL dalių suma „žemiau LPL + juoda“ atveju sumažėjo nuo 10,051 s iki 6,891 s. Vien „juoda“ filtro suma liko apie 10,55–10,92 s. Tai nėra viso RPC ar API laikas.

## Pakartojami planai

Bazinis planas yra dokumentuotas VPS analizėje ir saugomas pradiniuose `*_explain_2026-10-04.json` failuose. Žemiau esantys JSON failai yra pakartojimas B po `20261004100000_optimize_catalog_facet_prefilter.sql` pritaikymo:

- [Ne dydžių facetai: juoda](catalog_facets_black_after_prefilter_explain_2026-10-04.json)
- [Dydžių facetai: juoda](catalog_sizes_black_after_prefilter_explain_2026-10-04.json)
- [Ne dydžių facetai: žemiau LPL + juoda](catalog_facets_lpl_black_after_prefilter_explain_2026-10-04.json)
- [Dydžių facetai: žemiau LPL + juoda](catalog_sizes_lpl_black_after_prefilter_explain_2026-10-04.json)

## Metodas ir ribos

- Prisijungta per vietinį PuTTY tunelį kaip `codex_reader` prie `postgres`, PostgreSQL 17.6. Kiekviena sesija pradėta `BEGIN READ ONLY` ir baigta `ROLLBACK`; `transaction_read_only` buvo `on`.
- Naudoti tie patys du filtrų kontekstai kaip baziniuose planuose: `{"colorShades":["black"]}` ir `{"belowObserved30d":true,"priceComparison":"source_lpl","colorShades":["black"]}`.
- `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` vykdytas tiesioginiams gyvų `catalog_facets()` ir `catalog_build_contextual_size_facets()` SQL kūnams. Cache RPC nekviestas, nes cache miss gali įrašyti į DB.
- Kaip ir pirminiame tyrime, tik skaitymo teisėms neprieinamiems pagalbiniams kvietimams naudoti tuščius masyvus (šių scenarijų `excludeBasics` ir `excludeAccessories` filtrai neaktyvūs), o `catalog_simple_facet()` apvalkalas pakeistas `to_jsonb()`.
- `codex_reader` sesijos `statement_timeout` buvo `0`; tai nėra `authenticator` RPC 8 s limitas. Todėl 6,891 s dviejų dalių suma dar negarantuoja, kad visas RPC ar API atsakys per 8 s.
- Laikas svyravo tarp pakartojimų, todėl mažus pokyčius vertinti kaip triukšmo ribose. Matavimai neatspindi kontroliuoto šalto cache ir nėra realaus API p95.

## Tolimesni veiksmai

1. Optimizuoti effective dydžių narystės skaičiavimą, kuris vien „juoda“ scenarijuje tebėra apie 6 s.
2. Po šio pakeitimo pakartoti tuos pačius planus ir atskirai išmatuoti realaus cache miss RPC/API p95 per įprastą aplikacijos kelią.
3. OpenSearch svarstyti tik jei optimizuotas PostgreSQL kelias vis tiek nepasiekia našumo tikslo.
