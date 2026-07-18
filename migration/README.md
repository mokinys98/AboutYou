# Supabase → Contabo migracijos vykdymo žurnalas

Šiame kataloge saugoma etapais vykdoma migracijos dokumentacija. Pagrindinis planas yra
[`docs/contabo-vps-supabase-migration-plan.md`](../docs/contabo-vps-supabase-migration-plan.md).

## Fazės

| Fazė | Dokumentas | Būsena |
|---|---|---|
| 0 | [Source inventorizacija ir backup](0-source-inventorizacija.md) | Baigta: backup, R2 retention, Auth/SMTP inventorius ir VPS → R2 patikra atlikti; invite-only modelyje savitarnos recovery UI sąmoningai nediegiama |
| 1 | [Contabo platformos paruošimas](1-contabo-platformos-paruosimas.md) | Pagrindiniai vartai baigti: hardening, firewall, Docker, volumes, staging stack, Tunnel, R2 ir 5 min. monitorius veikia; liko išorinio alert pristatymo testas |
| 2 | [Pirmas restore rehearsal](2-pirmas-restore-rehearsal.md) | Katalogo-only restore ir pilnas naujausio automatinio R2 backup disposable restore sėkmingi; RTO `53 s`; source Auth vartotojai pagal invite-only sprendimą nemigruojami; liko istorinių Storage objektų sprendimas |
| 3A | [Duomenų rinkimo perjungimas į staging](3-duomenu-rinkimo-perjungimas.md) | Katalogo 500 produktų/target ir metadata 50 produktų canary sėkmingi; artifact, fizinis Storage read, refresh `38/38` ir post-canary WAL checkpoint patvirtinti |
| 3B | [Funkcijų ir atsparumo testas](3-funkciju-ir-atsparumo-testas.md) | Vykdoma: katalogo/metadata testai, host resursai, raw Storage read, disposable restore ir vidinis monitoringas atlikti; liko Auth flow, dalis aplikacijos funkcijų, Storage istorija, išorinis alert ir 250k/SLO |
| 4 | [Pages, Worker ir produkcinio perjungimo rehearsal](4-produkciniu-integraciju-perjungimo-rehearsal.md) | Preview → staging Worker → VPS kelias veikia; preflight pakartotinai `16/16` PASS 2026-07-19, automatinis backup/restore, RTO ir 5 min. monitorius patvirtinti; production cutover dar STOP dėl Auth, išorinio alert, Storage istorijos ir rollback vartų |
| 5 | [Produkcinis cutover](5-produkcijos-perjungimas.md) | Nepradėta: paruoštas freeze, secret change, smoke ir rollback runbook; vykdyti tik uždarius 4 fazės STOP vartus |
| 6 | [Stabilizavimas ir 24 h stebėjimas](6-stabilizavimas.md) | Nepradėta: paruoštos T+15 min., T+1 h., T+6 h. ir T+24 h. patikros bei ribos |

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
