# Gyva rinkimo patikra ir pakeitimų planas — 2026-09-27

Tikslas: prieš keičiant algoritmą patikrinti tikrą produkcinį URL ir atskirti katalogo bei metadata našumą. Produkcinis kodas, darbo grafikas ir DB nepakeisti.

## Patikrintas šaltinis

URL: https://www.aboutyou.lt/c/vyrams/premium/marskineliai-144268

URL paimtas iš tikros DB eilės užduoties GitHub žurnale, ne iš spėjamo kategorijų sąrašo. Tiesioginis VPS DB skaitymas neatliktas; `.env` neskaitytas.

[Produkcijos darbas 36346449956](https://github.com/mokinys98/AboutYou/actions/runs/36346449956), commit `7c4196e`:

- Target: `Premium - Marškinėliai`, part: `root`, attempt: 5.
- Task: `b7cfb040-195f-4da8-ae5d-0aa9f4d87150`.
- Surinkta ir išsaugota 2163, deklaruota 2191; 68 papildomi puslapiai.
- `termination_reason=stream-exhausted`, `coverage=0.987220447284345`.
- Rezultatas `blocked`; visas darbuotojas truko 49,085 s.

Vietinis gyvas bandymas tuo pačiu esamu provideriu, 15000 riba, 120 s timeout:

- Tie patys 2163 produktai, 2191 deklaruotas kiekis, 68 papildomi puslapiai.
- Trukmė 12,972 s. DB saugojimas į šią trukmę neįeina.
- `direct-stream`, `stream-exhausted`, `rateLimited=false`.
- Normalizavimas: received=2163, valid=2163, rejected=0.
- Paskutinis puslapis: 3 produktai, `hasNextState=false`.
- Visuose užfiksuotuose srauto paketuose: 2179 elementai, 2163 produktų kortelės, 16 kitų blokų. Vien neproduktiniai blokai nepaaiškina 2191 deklaruoto kiekio.
- Artefaktai: `test-results/catalog-diagnostics/2026-09-27T20-05-13-646Z/`.

### Nepriklausomas natūralaus slinkimo palyginimas

Svetainė atidaryta be userscript, puslapis slinktas iki stabilaus ID rinkinio. Pirmas bandymas: 2223 unikalūs ID, visi 2163 direct rinkiklio ID ir 60 papildomų; 188,507 s. Vien `[data-testid="enhancedGridMeasure"]` selektorius nėra pakankamas pagrindinei kategorijai atskirti, nes puslapyje yra keli tokie konteineriai.

Antras bandymas rinko papildomų kortelių DOM protėvius. Visi 60 papildomų ID priklauso atskirai sekcijai su antrašte **„Atrask tendencijas ir geriausius prekės ženklusĮkvėpimas Marškinėliai“**. Tai nėra pagrindinio kategorijos srauto papildomos prekės. Antrame bandyme rasti 2221 ID (2161 iš ankstesnio direct rinkinio ir tie patys 60 papildomų); ankstesnių `23721333` ir `31988789` nebebuvo. Bandymų laikas skiriasi; šių dviejų pokyčio priežastis atskirai nepatvirtinta. Abu bandymai neaptiko 403/429 stebėtuose srauto atsakymuose.

DOM protėvių ir tinklo statusų artefaktas: `test-results/natural-catalog-20260927.json`. Diagnostinis skriptas: `test-results/inspect-live-catalog-20260927.mjs`. Šie vietiniai failai ignoruojami Git. Pirmo bandymo suvestinę faile pakeitė antras bandymas; pirmas rezultatas išliko šios sesijos komandos išvestyje.

Šiame URL nėra įrodymo, kad rinkiklis pametė 28 pagrindinio tinklelio prekes. Yra pakartotas deklaruoto kiekio ir faktinio srauto neatitikimas, kurį retry politika paverčia pakartotiniais rinkimais ir `blocked`.

## Kaip veikia šis katalogo kelias

`catalog-queue.ts` rezervuoja konkrečią dalį; provideris atidaro jos URL ir įterpia `aboutyou-price-sort.user.js`. Skriptas dekoduoja pradinį svetainės `GetProductStreamV2`, aptinka svetainės dabartinį CategoryStreamService modulį ir puslapiuoja per `GetProductStreamPageV2` su šaltinio `nextState`. Produktai deduplikuojami pagal ID; neproduktiniai blokai apskaitomi atskirai.

Surinkus srautą, provideris normalizuoja produktus, darbuotojas juos išsaugo 100 produktų paketais ir tik tada vertina baigtį. `catalogCollectionDecision` priima natūraliai pasibaigusį direct srautą tik nuo 99 % deklaruoto kiekio. Šio URL 98,72 % atmetami. DB po penkto bandymo užduotį žymi `blocked`. Duomenų išsaugojimas dėl to neprarandamas.

`root` čia reiškia konkretaus target pradinį URL, šiuo atveju jau subkategoriją. Tai nereiškia bendros 70000 prekių „Drabužiai“ šaknies. Šiam bandymui 15000 riba neturi įtakos.

## Darbo grafikas ir metadata

[36345548232](https://github.com/mokinys98/AboutYou/actions/runs/36345548232): katalogo darbuotojas truko 2,231 s., paimta 0 užduočių, `no_runnable_task`.

[36344633258](https://github.com/mokinys98/AboutYou/actions/runs/36344633258): 0,723 s., paimta 0 užduočių, `no_runnable_task`.

Keturi katalogo ir vienas metadata kvietimas per valandą nėra išmatuotas 80/20 darbo laiko santykis. Daugiau kvietimų nepadeda, kai eilėje nėra tuo metu vykdytinų užduočių.

Paskutinių 12 darbų (17:15–20:00 UTC kvietimų) palyginimas: 8 darbai paėmė 0 užduočių. Kiti 4 darbai turėjo 52 užduočių baigtis; visos 52 buvo `stream-exhausted`, 31 baigtis `blocked`. Tai užduočių bandymai, ne 52 unikalios kategorijos. Pavyzdžiui, [36341864385](https://github.com/mokinys98/AboutYou/actions/runs/36341864385) apdorojo 20 užduočių, 19 tapo `blocked`; darbuotojas dirbo 426,770 s. `saved` skaičiuoja priimtus įrašus / atnaujinimus, ne būtinai naujas unikalias katalogo prekes.

[Metadata 36345667456](https://github.com/mokinys98/AboutYou/actions/runs/36345667456):

- 100 sėkmingų produktų iki planinės rotacijos.
- Po rotacijos dar 26 sėkmingi, tik tada timeout serija.
- Galutinis rezultatas: complete=126, retryable=14, claimed=200, trukmė 540 s.; circuit atsidarė.
- `claimed` nėra realiai išsiųstų produkto užklausų ar naujai atrastų prekių skaičius.
- Produkcinis kvietimas `fetchProductDetail(context, url)` neperduoda funkcijos palaikomų tinklo diagnostikos callback. Bendras 25 s timeout neatskleidžia, ar sustojo navigacija, RPC atsakymas, jo turinio gavimas, ar dekodavimas.

Tai neįrodo, kad rotacija sukelia timeout ar kad rotacijos panaikinimas duos 500–700 produktų per 10 min. Jau be klaidų 25 produktų paketai šiame darbe trunka apie 47–53 s. Ankstesnė 750 riba buvo tik teorinė pagal užklausų starto intervalą.

Gyvai esama `diagnose:metadata` komanda patikrinti ką tik surinkti `32225379`, `31680845`, `8350435`. Visi trys: HTTP 200, `mode=network`, `ok=true`, teisingas produkto ID, `failure=null`. Naudotas esamas `fetchProductDetail`, išsaugoti tinklo įvykiai ir trace: `apps/sync/test-results/metadata-diagnostics/summary.json`. Komanda neskaito `.env` ir nekuria DB kliento. Tai trijų nuoseklių užklausų patikra vietiniame tinkle, ne ilgalaikės GitHub apkrovos eksperimentas.

## Pakeitimų planas pagal įrodymus

1. **Katalogo baigties klasifikacija.** Gavus sutampantį natūralaus UI ir direct ID rinkinį, paruošti atskirą baigtį „srautas baigtas, deklaruoto kiekio neatitikimas“. Tokia baigtis saugotų prekes ir nesukeltų penkių vienodų retry dėl vien skaitiklio neatitikimo. Ji neturi suteikti teisės išjungti nematytas prekes. Timeout, strigimas, normalizavimo praradimai ir ribos pasiekimas lieka atskiri nepilni rezultatai. Prieš taikant visoms kategorijoms, pakartoti ID palyginimą bent kitai neatitinkančiai kategorijai.
2. **Viso katalogo aprėptis.** Perskaityti realius target URL, jų dalis ir naujausias būsenas; palyginti unikalių ID sąjungą. Paruošta tik skaitymo užklausa `docs/KATALOGO_PATIKRA_20260927.sql`, ji nevykdyta. Skaidyti tik faktiškai ribą pasiekiančias dalis. Nepriskirti viso 55 tūkst. / 69–71 tūkst. skirtumo vienam patikrintam URL.
3. **Metadata matavimas.** Pirmiausia pridėti etapų trukmes ir ribotą diagnostiką pirmam timeout: dokumento statusas, ar RPC buvo išsiųstas, ar gautas atsakymas, turinio ir dekodavimo baigtis. Neįrašyti cookie, tokenų ar sesijos antraščių.
4. **Kontroliuojamas palyginimas.** Tame pačiame GitHub vykdymo tipe, su tuo pačiu viešų produktų rinkiniu ir be DB rašymo palyginti dabartinę 100 bandymų rotaciją su ilgesniu konteksto naudojimu. Išlaikyti 3 workerius ir 800 ms startų intervalą; bandymus vykdyti nuosekliai su atvėsimo tarpu, stabdyti ties 403/429 ar pasikartojančiais timeout. Matuoti sėkmes/min., p95 gavimo trukmę, klaidos etapą ir timeout pradžios tašką. Vienas 108 užklausų bandymas nepatvirtina ilgalaikio stabilumo.
5. **Optimizacija pagal rezultatą.** Puslapių naudojimą pakartotinai ar resursų blokavimą vertinti atskirai, po vieną pakeitimą ir su tais pačiais ID bei payload teisingumo testais. Rotacijos limito ar concurrency nekeisti vien pagal spėjimą.
6. **Grafikas.** Tik po matavimų spręsti balansą pagal realiai užimtą laiką, vykdytinų užduočių skaičių, naujų unikalių ID prieaugį ir metadata sėkmes. Dabar 50/50 nėra pagrįstas gydymas.

## Ribos

Ši patikra nepatvirtina visų produkcinių target aprėpties ir neįrodo metadata timeout priežasties. Vietinis tinklas skiriasi nuo GitHub runner tinklo. Jokių produkcinių pakeitimų ar naujų produkcinių sync paleidimų šiai patikrai nedaryta.
