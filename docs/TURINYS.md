# Dokumentacijos turinys

Šis failas yra pagrindinis projekto dokumentacijos įėjimo taškas. Projekto šaknyje
sąmoningai palikti tik `README.md` ir `AGENTS.md`; visa kita dokumentacija laikoma
šiame `docs/` kataloge.

Progresas yra praktinis įvertis nuo `0/100` iki `100/100`:

- `0/100` – darbas nepradėtas;
- `1–99/100` – yra atliktų dalių, bet planas dar turi neuždarytų punktų;
- `100/100` – darbas baigtas; dokumentą galima pašalinti, kai jo svarbios išvados
  perkeltos į nuolatinę dokumentaciją.

## Aktyvūs ir būsimi darbai

| Dokumentas | Paskirtis | Progresas |
|---|---|---:|
| [Dirbtinio intelekto integravimas](DIRBTINIO_INTELEKTO_INTEGRAVIMAS_I_PROJEKTA.md) | Produkto vaizdo analizė, vartotojo spalvų profilis ir deterministinis tinkamumo balas. Darbas dar nepradėtas. | **0/100** |
| [Telegram alertų publikavimo planas](TELEGRAM_ALERTU_PLANAS.md) | Kode įgyvendinto publikacijos versijavimo rollout, produkcinės patikros ir būsimi alertų scenarijai. | **57/100** |
| [Supabase → VPS migracijos užbaigimas](MIGRACIJOS_UZBAIGIMAS.md) | Jau atliktos migracijos santrauka, likę stabilizavimo darbai ir rollback procedūra. | **100/100** |
| [Techninių darbų planas](TECHNINIU_DARBU_PLANAS.md) | Admin dashboard, raw payload Storage, read modelio ir mažesnių techninių darbų backlog. | **45/100** |

## Nuolatinė techninė dokumentacija

| Dokumentas | Paskirtis | Būsena |
|---|---|---:|
| [ABOUT YOU duomenys ir atributai](ABOUTYOU_DUOMENU_ATRIBUTAI.md) | Kaip renkami produktai, kokie atributai saugomi ir kokios duomenų spragos dar žinomos. | **100/100 analizė** |

## Dokumentų gyvavimo taisyklė

1. Naujas didesnis darbas aprašomas atskirame plane šiame kataloge.
2. Planas turi progresą ir paskutinį punktą `Baigta – galima ištrinti`.
3. Užbaigus darbą, ilgalaikės architektūrinės žinios perkeliamos į nuolatinį
   dokumentą.
4. Baigtas planas ištrinamas; jo istorija lieka Git.
5. `TURINYS.md` atnaujinamas kartu su kiekvienu plano sukūrimu, uždarymu ar trynimu.
