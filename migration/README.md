# Supabase → Contabo migracijos vykdymo žurnalas

Šiame kataloge saugoma etapais vykdoma migracijos dokumentacija. Pagrindinis planas yra
[`docs/contabo-vps-supabase-migration-plan.md`](../docs/contabo-vps-supabase-migration-plan.md).

## Fazės

| Fazė | Dokumentas | Būsena |
|---|---|---|
| 0 | [Source inventorizacija ir backup](0-source-inventorizacija.md) | Pradėta; pasirinktas R2, laukiama session pooler DB jungties ir R2 paruošimo |
| 1 | Contabo platformos paruošimas | Nepradėta |
| 2 | Pirmas restore rehearsal | Nepradėta |
| 3 | Funkcijų ir atsparumo testas | Nepradėta |
| 4 | 250k apkrovos ir recovery rehearsal | Nepradėta |
| 5 | Produkcinis cutover ir 24 h stebėjimas | Nepradėta |

## Dokumentavimo taisyklės

- Kiekviena fazė turi atskirą `.md` failą šiame kataloge.
- Dokumentuojamos datos, vykdyti veiksmai, komandos, patikros, rezultatai, neatitikimai ir sprendimai.
- Slapta informacija, connection string'ai, JWT/API raktai, dump'ai ir Storage objektai į Git nepatenka.
- Fazė uždaroma tik surinkus jos stop/go vartų įrodymus.
- Produkciniai pakeitimai neatliekami vien todėl, kad jie aprašyti dokumente.
