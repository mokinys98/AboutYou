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

## Ankstesnė išvada po pirminės optimizacijos

1. Optimizuoti effective dydžių narystės skaičiavimą, kuris vien „juoda“ scenarijuje tebėra apie 6 s.
2. Po šio pakeitimo pakartoti tuos pačius planus ir atskirai išmatuoti realaus cache miss RPC/API p95 per įprastą aplikacijos kelią.
3. OpenSearch svarstyti tik jei optimizuotas PostgreSQL kelias vis tiek nepasiekia našumo tikslo.

## Pakartojimas po effective dydžių modelio ir semantikos migracijų

2026-10-04 15:11 UTC skaitymo režimu PostgreSQL 17.6 per tą patį PuTTY tunelį pakartoti tie patys keturi `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` scenarijai. VPS metaduomenyse matomi `20261004110000`, `20261004120000` ir `20261004130000` migracijų pakeitimai. Tai bendras rezultatas po visų trijų pakeitimų, o ne izoliuotas vienos migracijos poveikis. Kaip ankstesniuose matavimuose, vykdyti gyvų funkcijų skaitantys SQL kūnai, neveikiantys `excludeBasics` ir `excludeAccessories` pagalbiniai kvietimai pakeisti tuščiais masyvais, o `catalog_simple_facet()` apvalkalas – `to_jsonb()`. Visi matavimai atlikti `BEGIN READ ONLY` / `ROLLBACK` sesijose; cache RPC nekviestas.

| Scenarijus | Po pirminės optimizacijos B | Po trijų migracijų | Pokytis |
| --- | ---: | ---: | ---: |
| Ne dydžių facetai: juoda | 4 944,411 ms | 4 235,849 ms | −14,3 % |
| Dydžių facetai: juoda | 5 970,691 ms | 889,822 ms | −85,1 % |
| Ne dydžių facetai: žemiau LPL + juoda | 1 797,183 ms | 1 996,154 ms | +11,1 % |
| Dydžių facetai: žemiau LPL + juoda | 5 093,993 ms | 243,121 ms | −95,2 % |

Dviejų SQL dalių suma „tik juoda“ sumažėjo nuo **10,915 s iki 5,126 s** (apie −53 %), o „žemiau LPL + juoda“ – nuo **6,891 s iki 2,239 s** (apie −67 %). Tai pavieniai SQL planų matavimai, ne API cache miss p50/p95; mažesni ne dydžių dalies skirtumai gali būti matavimo svyravimas. Dabartinė SQL dalių suma abiem scenarijais mažesnė už 8 s, tačiau galutinis RPC ir API limitas dar nepatikrintas.

Žali planai: [ne dydžių facetai, juoda](catalog_facets_black_after_effective_model_explain_2026-10-04.json), [dydžių facetai, juoda](catalog_sizes_black_after_effective_model_explain_2026-10-04.json), [ne dydžių facetai, LPL + juoda](catalog_facets_lpl_black_after_effective_model_explain_2026-10-04.json), [dydžių facetai, LPL + juoda](catalog_sizes_lpl_black_after_effective_model_explain_2026-10-04.json).

Effective narystės materializuotas modelis turi **364 401** eilutę. Jo lentelė užima **48 734 208 B**, indeksai **37 036 032 B**, iš viso **85 819 392 B** (apie **81,8 MiB**). Refresh trukmė ir CPU pokytis dar neišmatuoti.

## Tolimesni veiksmai dabar

1. Patikrinti realius facetų ir produktų kiekius su „juoda“, „žemiau LPL + juoda“, grupuotais ir senais dydžių tokenais, `otherSizes`, override ir alertais.
2. Po API ir web pakeitimų diegimo per įprastą autentifikuotą aplikacijos kelią išmatuoti cache miss ir hit p50/p95 bei timeout skaičių; SQL planų sumų nelaikyti šio matavimo pakaitalu.
3. Per katalogo refresh ir klasifikacijos override užfiksuoti materializuoto modelio atnaujinimo trukmę bei VPS CPU. Jei API p95 vis dar viršija tikslą, pagal naujus planus optimizuoti likusią brangiausią dalį.
