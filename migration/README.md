# Supabase → Contabo migracijos vykdymo žurnalas

Šiame kataloge saugoma etapais vykdoma migracijos dokumentacija. Pagrindinis planas yra
[`docs/contabo-vps-supabase-migration-plan.md`](../docs/contabo-vps-supabase-migration-plan.md).

## Fazės

| Fazė | Dokumentas | Būsena |
|---|---|---|
| 0 | [Source inventorizacija ir backup](0-source-inventorizacija.md) | Baigta: backup, R2 retention, Auth/SMTP inventorius ir VPS → R2 patikra atlikti; invite-only modelyje savitarnos recovery UI sąmoningai nediegiama |
| 1 | [Contabo platformos paruošimas](1-contabo-platformos-paruosimas.md) | Pagrindiniai vartai baigti: hardening, firewall, Docker, volumes, staging stack, Tunnel ir R2 veikia; Docker ir Postgres/WAL checkpoint atliktas, liko monitoring/alertai |
| 2 | [Pirmas restore rehearsal](2-pirmas-restore-rehearsal.md) | Katalogo-only restore, row-count ir web/API smoke testai sėkmingi; source Auth vartotojai pagal invite-only sprendimą nemigruojami; liko fizinė Storage parity ir disposable restore su RTO |
| 3A | [Duomenų rinkimo perjungimas į staging](3-duomenu-rinkimo-perjungimas.md) | Katalogo 500 produktų/target ir metadata 50 produktų canary sėkmingi; artifact, Storage write ir refresh `38/38` patvirtinti, liko raw read ir WAL palyginimas |
| 3B | [Funkcijų ir atsparumo testas](3-funkciju-ir-atsparumo-testas.md) | Vykdoma: katalogo apkrovos ir host resursų testas atliktas; liko metadata, Auth/JWKS, aplikacijos funkcijos, Storage, restore, monitoring ir 250k/SLO |
| 4 | [Pages, Worker ir produkcinio perjungimo rehearsal](4-produkciniu-integraciju-perjungimo-rehearsal.md) | Preview → staging Worker → VPS kelias veikia; viešas preflight `16/16` PASS, production cutover dar STOP dėl likusių Auth, backup/restore, monitoring ir rollback vartų |
| 5 | Produkcinis cutover | Nepradėta |
| 6 | Stabilizavimas ir 24 h stebėjimas | Nepradėta |

## Branch tvarka

- Migracijos dokumentacijos source of truth yra `main` branch.
- Ankstesnis `agent/document-auth-recovery-test` branch yra istorinis darbo branch; jame buvusios aktualios pataisos perkeltos į `main` rankiniu būdu kartu su naujesniais 500/target rezultatais.
- Nauji migracijos sprendimai ir progreso varnelės atnaujinami `main` esančiuose `migration/*.md` dokumentuose; atskiras ilgalaikis migracijos branch nekuriamas.

## Dokumentavimo taisyklės

- Kiekviena fazė turi atskirą `.md` failą šiame kataloge.
- Dokumentuojamos datos, vykdyti veiksmai, komandos, patikros, rezultatai, neatitikimai ir sprendimai.
- Slapta informacija, connection string'ai, JWT/API raktai, dump'ai ir Storage objektai į Git nepatenka.
- Fazė uždaroma tik surinkus jos stop/go vartų įrodymus.
- Produkciniai pakeitimai neatliekami vien todėl, kad jie aprašyti dokumente.
