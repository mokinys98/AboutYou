# Katalogo dydžių domenų inventorizacija — 2026-10-09

Duomenys nuskaityti iš `public.catalog_size_facets_read` per patvirtintą VPS tunelį, naudojant `codex_reader` ir tik `BEGIN READ ONLY` transakcijas. Apskaičiuotos visos 18 dydžių domenų grupės ir 2 494 skirtingos domeno / rakto / etiketės kombinacijos. VPS duomenys nekeisti.

## Domenai ir dabartinis dydžių turinys

| Domenas | Eilučių | Produktų | Skirtingų raktų | Saugi grupavimo taisyklė |
|---|---:|---:|---:|---|
| accessories | 1 573 | 1 513 | 32 | Vieno dydžio aliasai ir aiškūs raidiniai dydžiai; matmenų nekeisti |
| bags | 1 971 | 1 966 | 23 | Suvienodinti vieno dydžio aliasus; palikti matmenis ir įrenginių modelius |
| belts | 4 885 | 1 563 | 36 | Palikti skaitinius dydžius ir intervalus |
| bracelets | 677 | 486 | 38 | Palikti cm matmenis, dešimtaines reikšmes ir intervalus |
| clothing | 83 786 | 23 785 | 91 | Standartizuoti raidinius dydžius, aliasus ir žinomus aprašus; skaidyti raidinius dydžių intervalus |
| eyewear | 1 545 | 1 543 | 34 | Suvienodinti „one size“ / „Einheitsgröße“; kitų reikšmių nekeisti |
| gloves | 306 | 114 | 23 | Standartizuoti raidinius dydžius ir skaidyti raidinius dydžių intervalus |
| headwear | 3 377 | 2 952 | 46 | Palikti galvos apimčių intervalus; skaidyti aiškius raidinius dydžių intervalus |
| other | 4 438 | 1 260 | 130 | Pašalinti tik žinomą dydžio aprašą; neaiškius ir sudėtinius raktus palikti |
| rings | 743 | 225 | 29 | Palikti žiedų skaitinius dydžius |
| shirts | 100 560 | 30 688 | 226 | Standartizuoti raidinius dydžius, aliasus ir žinomus aprašus; skaidyti raidinius dydžių intervalus |
| shoes | 51 835 | 9 478 | 445 | Pašalinti žinomą aprašą; palikti EU dydžius, pusinius dydžius ir intervalus |
| socks | 3 407 | 1 503 | 84 | Palikti skaitinius dydžius ir intervalus; skaidyti aiškius raidinius dydžių intervalus |
| suitwear | 3 791 | 1 190 | 164 | Pašalinti dydžio aprašus, bet išlaikyti skaitinius EU dydžius |
| swimwear | 3 487 | 1 137 | 61 | Standartizuoti raidinius dydžius, aliasus ir žinomus aprašus; skaidyti raidinius dydžių intervalus |
| trousers | 98 182 | 17 521 | 917 | Tik aiškias W/L poras versti į W/L; palikti dviprasmiškus skaitinius intervalus atskirai |
| underwear | 10 850 | 3 162 | 69 | Standartizuoti raidinius dydžius, aliasus ir žinomus aprašus; skaidyti raidinius dydžių intervalus |
| wallets | 338 | 337 | 10 | Suvienodinti vieno dydžio aliasus; palikti modelių ir išmatavimų reikšmes |

## Aptikti bendri užrašų šablonai

- Raidinis dydis su pridėtu `Normalaus dydžio / Normalaus dydžio`.
- Skaitinis dydis su `įprastas ilgis`, `trumpas`, `labai ilgas` ir panašiais aprašais.
- Dublikuotas `Vienas dydis` užrašas bei `OneSize`, `NS` ir vokiečių `Einheitsgröße`.
- Tikri skaitiniai intervalai: batų pusiniai dydžiai, kojinių intervalai, kepurių apimtys, diržų dydžiai ir apyrankių cm matmenys.
- Aksesuarų bei krepšių matmenys, žiedų numeriai ir telefono modeliai, kuriuos negalima interpretuoti kaip drabužių dydžius.

## Pritaikymo statusas

Atnaujinta [20261009110000 migracija](../../supabase/migrations/20261009110000_normalize_trouser_length_facets.sql) taiko žinomų aprašų šalinimą efektyviam dydžių vaizdui ir saugo skirtingas dydžių sistemas. Ji lokali ir dar nelaikoma pritaikyta VPS. Prie jos paruošta [skaitymo režimo patikra](VERIFY_20261009110000_normalize_trouser_length_facets.sql). Pritaikymo bei facetų perskaičiavimo rezultatas fiksuojamas tik gavus naudotojo SQL Editor išvestį arba atlikus atskirą autorizuotą skaitymo patikrą.
