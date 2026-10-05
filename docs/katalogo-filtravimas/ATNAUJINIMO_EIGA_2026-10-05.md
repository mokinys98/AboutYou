# Katalogo filtravimo darbai 2026-10-05

## Sprendimas pagal 2026-10-04 matavimus

Šešios skirtingos API cache miss / hit poros buvo sėkmingos, tačiau jų neužtenka
patikimam p95. Pilnas `catalog_effective_size_membership_read` atnaujinimas yra
susijęs su `AccessExclusiveLock`; vakar per tokį ciklą stebėtas produktų API
HTTP 500. Vienas ciklas trunka apie keturias minutes iš penkių minučių
intervalo. Todėl pirmiausia tikrinamas ir mažinamas refresh poveikis skaitymui,
o pilnas API matavimas atliekamas po to.

## Paruošta lokaliai

- [Prieš pakeitimą vykdoma skaitymo režimo diagnostika](../../supabase/tests/diagnose_nonblocking_refresh_preflight_read_only.sql)
  patikrina dabartinę versiją, funkcijos savininką, pilną refresh, greitą
  statinių dydžių kelią, unikalaus indekso tinkamumą ir momentinį užraktą.
- [Migracija](../../supabase/migrations/20261005090000_nonblocking_effective_size_refresh.sql)
  keičia tik effective dydžių vaizdo atnaujinimą į `CONCURRENTLY`, išsaugo
  vakarykštį statinio dydžių skaičiavimo optimizavimą ir fazių klaidų žymas.
  Ji nepradeda refresh. Kitas suplanuotas ciklas parodys, ar visas kelias
  telpa į 300 s ribą. **VPS dar nepritaikyta.**
- [Patikra po migracijos](../../supabase/tests/verify_nonblocking_effective_size_refresh_read_only.sql)
  tikrina funkciją, indeksą, katalogo versijas, paskutinio ciklo trukmę ir
  momentinį `AccessExclusiveLock`. [Statinio cache lygybės patikra](../../supabase/tests/verify_catalog_static_size_reuse_read_only.sql)
  papildomai palygina cache turinį su paruošta naryste.
- API matuoklis turi `--start-index` vienos ar dviejų porų segmentams per
  skirtingus stabilius langus. Kiekviena pora įrašo katalogo versiją prieš ir
  po užklausų; versijai pasikeitus ji nelaikoma galiojančia.

## Šiandienos patikros būsena

Vietinis `127.0.0.1:15432` tunelio portas šios sesijos metu nepriėmė TCP
ryšio. Dėl to šiandienos VPS būsenos, migracijos taikymo ir jos poveikio
patvirtinimo dar nėra. Vakar patvirtinta būsena nėra šiandienos matavimas.

## Tolesnė eiga

1. Atkūrus tunelį, per `codex_reader` tik skaitymo transakciją paleisti
   diagnostiką. Jei tunelis nepasiekiamas, naudotojas gali ją vykdyti VPS
   Supabase SQL Editor ir pateikti rezultatą.
2. Kai preflight patvirtina numatytą funkcijos ir indekso būseną, naudotojas
   įkelia migracijos failą į VPS Supabase SQL Editor ir paleidžia jį. Užfiksuoti
   atskirą SQL Editor sėkmės išvestį.
3. Po kito paprašyto cron ciklo skaitymo režimu patikrinti versijų sutapimą,
   ciklo trukmę, klaidą, statinio cache lygybę ir produktų API elgseną ciklo
   metu. Pakartoti bent per tris atnaujinimus. Jei ciklas viršija limitą,
   prieš kitą pakeitimą surinkti fazės klaidą.
4. Tik stabilizavus refresh tęsti bent 120 skirtingų API porų matavimą per
   versijomis pažymėtus segmentus ir pakartoti jį kitu metu. Kiekvienam
   segmentui naudoti naują rezultatų failą, pavyzdžiui, `--per-group 1
   --start-index 0`, kitam `--start-index 1`. Galutiniame sujungime tikrinti
   unikalius normalizuotus filtrų raktus, ne vien scenarijų ID.
