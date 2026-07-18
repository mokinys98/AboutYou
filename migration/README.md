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
| 3B | [Funkcijų ir atsparumo testas](3-funkciju-ir-atsparumo-testas.md) | Minimalus paleidimo kriterijus priimtas: katalogo/metadata canary, host resursai, raw Storage read, disposable restore ir vidinis monitoringas atlikti; pilnas metadata/SLO ir neesminės integracijos tęsiamos po cutover |
| 4 | [Pages, Worker ir produkcinio perjungimo rehearsal](4-produkciniu-integraciju-perjungimo-rehearsal.md) | Preview → staging Worker → VPS kelias veikia; Worker backend origin patikra ir preflight `17/17` PASS, backup/restore bei monitorius patvirtinti; išorinis alert, pilnas Auth, Telegram ir sena diagnostinė Storage istorija priimti kaip post-cutover darbai |
| 5 | [Produkcinis cutover](5-produkcijos-perjungimas.md) | Vykdomas: Pages ir Worker perjungti į VPS, cutover preflight `18/18 PASS`, cron’ai atkurti, metadata 50/50 canary sėkmingas; vyksta pilnas katalogo sync, liko rankinis UI smoke ir finalus checkpoint |
| 5A | [Production VPS taskeris](5a-production-vps-taskeris.md) | `production-vps` environment ir abu secret’ai aktyvūs, source repo secret’ai palikti rollback’ui; metadata canary sėkmingas, katalogo run paleistas |
| 6 | [Stabilizavimas ir 24 h stebėjimas](6-stabilizavimas.md) | Pradėtas 2026-07-18 22:49 UTC; pilnas 24 h. uždarymas galimas tik po catalog run, UI smoke ir numatytų checkpointų |

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
