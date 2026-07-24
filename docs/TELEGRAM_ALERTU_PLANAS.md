# Telegram alertų publikavimo planas

**Progresas:** 57/100  
**Būsena:** kodas įgyvendintas, produkcinis rollout ir priėmimo patikros neužbaigtos  
**Sujungta iš:** `TeleGram FIX.md` ir `TelegramBot UseCase.md`

## Tikslas

Telegram alertas turi būti vertinamas tik pagal jau publikuotą katalogo read modelio
versiją. Pranešimas negali aplenkti katalogo refresh, o pakartotinis siuntimas negali
sukurti antro loginio įvykio.

## Atlikta kode

- [x] Alertams pridėtas `last_evaluated_catalog_version` kursorius.
- [x] Filtro alertai vertinami iš `catalog_items_read`.
- [x] Outbox įrašams pridėtas `required_catalog_version` saugiklis.
- [x] Nepublikuotos katalogo versijos outbox eilutės neclaiminamos.
- [x] `event_key` susietas su katalogo publikacijos versija.
- [x] Telegram filtro URL perduoda `catalog_version`.
- [x] Web katalogo ir facetų užklausos naudoja `catalog_version`, todėl senas cache
  negali parodyti ankstesnės kartos.
- [x] Naujas arba pakeistas alertas pradedamas nuo tuo metu publikuotos versijos.
- [x] Kodo pakeitimas yra migracijoje
  `../supabase/migrations/202607210001_telegram_catalog_publication_gate.sql`.
- [x] VPS read-model `pg_cron` veikimas ir rankinis refresh buvo patikrinti migracijos
  metu.
- [x] Testinis Telegram pranešimo paspaudimas buvo patikrintas ankstesnio rollout metu.
- [x] Production boto perjungimas į VPS pažymėtas atliktu migracijos žurnale.
- [x] Profilio Telegram atjungimo komanda įgyvendinta kode.

## Dar reikia atlikti

- [ ] Paleisti `npm test`, `npm run typecheck` ir `git diff --check` prieš rollout.
- [ ] Prieš DB pakeitimą patvirtinti šviežią backup ir užfiksuoti
  `requested_version`, `completed_version` bei laukiančių outbox eilučių skaičių.
- [ ] Patvirtinti, kad migracija pritaikyta produkcinėje VPS duomenų bazėje.
- [ ] Patikrinti naujus stulpelius, funkcijų signatūras ir alertų backfill.
- [ ] Išbandyti seną edge ir naršyklės cache prieš bei po naujo refresh.
- [ ] Išbandyti Telegram 429/5xx retry, nepublikuotos versijos ir dalinio sync
  scenarijus.
- [ ] Aiškiai patvirtinti partial sync publikavimo politiką.
- [ ] Stebėti bent kelis realius sync → refresh → evaluate → send ciklus.
- [ ] Patikrinti `/start`, `/status`, profilio susiejimą ir atjungimą pagrindiniame
  production domene.
- [ ] Užfiksuoti rollout datą, migracijos versiją ir galutinį rezultatą.

## Prioritetiniai naudojimo scenarijai

1. Naujas produktas stebimoje kategorijoje arba prekės ženkle.
2. Stebimos prekės kaina nukrenta žemiau vartotojo nustatyto slenksčio.
3. Kaina nukrenta žemiau 30 dienų stebėto minimumo.
4. Kaina tampa mažesnė už ABOUT YOU pateiktą paskutinę mažiausią kainą.
5. Naujas produktas atitinka vartotojo premium, medžiagos, spalvos ar kitus filtrus.
6. Stebima prekė grįžta į katalogą arba vėl tampa aktyvi.
7. Produktui atsiranda nauja spalva, dydis ar išsamesni metadata duomenys.

Pirma versija turi koncentruotis į naujus produktus, watchlist ir kainos kritimus.
Kokybės bei panašumo alertai paliekami vėlesniam etapui, nes jų patikimumas priklauso
nuo pilno metadata užpildymo.

## Priėmimo kriterijai

- alertas niekada neišsiunčiamas prieš atitinkamos katalogo versijos publikavimą;
- tas pats loginis įvykis nesukuria dviejų pranešimų;
- Telegram retry kartoja tos pačios outbox eilutės pristatymą;
- naujas refresh vertinimo metu neprarandamas ir apdorojamas kitu ciklu;
- vartotojo nuoroda atidaro tą pačią arba naujesnę katalogo versiją;
- produkciniai patikrinimai ir keli realūs ciklai užfiksuoti be klaidų.

## Dokumento uždarymas

- [ ] Baigta – galima ištrinti
