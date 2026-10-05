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
  telpa į 300 s ribą. Naujas funkcijos apibrėžimas jau matomas VPS per
  skaitymo tunelį; atskira SQL Editor „Success“ išvestis dar negauta.
- [Patikra po migracijos](../../supabase/tests/verify_nonblocking_effective_size_refresh_read_only.sql)
  tikrina funkciją, indeksą, katalogo versijas, paskutinio ciklo trukmę ir
  momentinį `AccessExclusiveLock`. [Statinio cache lygybės patikra](../../supabase/tests/verify_catalog_static_size_reuse_read_only.sql)
  papildomai palygina cache turinį su paruošta naryste.
- API matuoklis turi `--start-index` vienos ar dviejų porų segmentams per
  skirtingus stabilius langus. Kiekviena pora įrašo katalogo versiją prieš ir
  po užklausų; versijai pasikeitus ji nelaikoma galiojančia.

## Šiandienos patikros būsena

Iš pradžių vietinis `127.0.0.1:15432` tunelio portas nepriėmė TCP ryšio.
Naudotojui jį atkūrus, 06:28 UTC `codex_reader` skaitymo transakcija patvirtino:
`concurrent_refresh_installed = true`, `fast_static_dictionary_retained = true`,
`slow_static_rebuild_absent = true`, `concurrent_index_ready = true`. Tuo metu
vyko 2105 versijos ciklas: ant effective dydžių vaizdo buvo suteiktas
`ExclusiveLock`, bet ne `AccessExclusiveLock`. Naudotojo po migracijos paleistas
preflight parodė `full_refresh_installed = false`; tai laukiamas senojo kelio
nebuvimo požymis, ne naujos migracijos klaida.

06:29:55 UTC skaitymo patikroje 06:25:00–06:29:11 UTC ciklas jau buvo
**sėkmingai baigęsis per 251 889 ms**: `requested_version = completed_version =
2105`, `last_status = refreshed`, `last_error = null`. 06:30:33 UTC būsena buvo
`clean`. Tai vienas po funkcijos pakeitimo tiesiogiai patikrintas ciklas.

Naudotojo atskira SQL Editor migracijos **„Success“ išvestis dar negauta**, todėl
formalus nuotolinio taikymo patvirtinimas nefiksuojamas; funkcijos apibrėžimas
ir ciklo rezultatas patikrinti atskirai. `codex_reader` negali skaityti statinio
dydžių cache lentelės, todėl jo turinio lygybės dar reikia SQL Editor patikros.
Produktų API prieinamumas aktyvaus ciklo metu taip pat dar nepatikrintas.

## Tolesnė eiga

1. Atkūrus tunelį, per `codex_reader` tik skaitymo transakciją paleisti
   diagnostiką. Jei tunelis nepasiekiamas, naudotojas gali ją vykdyti VPS
   Supabase SQL Editor ir pateikti rezultatą.
2. Naudotojas pateikia jau vykdytos migracijos SQL Editor sėkmės išvestį.
   Migracijos nekartoti vien dėl to, kad po jos paleistas preflight grąžino
   `full_refresh_installed = false`.
3. Po kito paprašyto cron ciklo skaitymo režimu patikrinti versijų sutapimą,
   ciklo trukmę, klaidą, statinio cache lygybę ir produktų API elgseną ciklo
   metu. Pakartoti bent per tris atnaujinimus. Jei ciklas viršija limitą,
   prieš kitą pakeitimą surinkti fazės klaidą.
4. Tik stabilizavus refresh tęsti bent 120 skirtingų API porų matavimą per
   versijomis pažymėtus segmentus ir pakartoti jį kitu metu. Kiekvienam
   segmentui naudoti naują rezultatų failą, pavyzdžiui, `--per-group 1
   --start-index 0`, kitam `--start-index 1`. Galutiniame sujungime tikrinti
   unikalius normalizuotus filtrų raktus, ne vien scenarijų ID.
