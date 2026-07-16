# 2 fazė — pirmas restore rehearsal

## Progreso blokas

- [x] Staging Supabase stack paleistas ir visi servisai healthy.
- [x] Staging API pasiekiamas per Cloudflare Tunnel.
- [ ] Į VPS saugiai pristatytas pasirinktas source dump artefaktas iš R2.
- [ ] Dump parašas / checksum patikrintas prieš dešifravimą.
- [ ] Source dump iššifruotas naudojant VPS age identity; private key į logus nepatenka.
- [ ] Atkurtos roles, schema ir data į staging DB.
- [ ] Atlikti row-count, lentelių, Auth/Storage ir pagrindinių API smoke testai.
- [ ] Užfiksuotas restore laikas, klaidos, duomenų dydis ir rollback pastabos.

**Būsena:** pasiruošta pradėti restore rehearsal. Produkcinis Supabase ir production refresh šiame etape neliečiami.

## Tikslas

Patikrinti, ar iš 0 fazėje paruoštų šifruotų artefaktų galima atkuriamai atstatyti staging Supabase duomenų bazę.

## Įėjimo sąlygos

- Staging URL: `https://supabase-staging.rinkissaupigiausia.online`
- Staging stack katalogas: `/srv/supabase/docker`
- Backup laikinas katalogas: `/srv/supabase/backups/restore-rehearsal-<timestamp>`
- R2 artefaktai imami tik per bucket’ui apribotą backup API tokeną.
- age private identity naudojama tik VPS secret saugykloje; ji nekopijuojama į repository ir neįrašoma į shell history.

## Vykdymo seka

1. Sukurti restore darbo katalogą su `0700` teisėmis.
2. Iš R2 atsisiųsti konkretų roles/schema/data dump artefaktą.
3. Patikrinti checksum arba parašą.
4. Dešifruoti į laikiną failą, neperrašant source artefaktų.
5. Staging DB sustabdymo / restore procedūrą atlikti pagal dump tipą.
6. Paleisti stack ir patikrinti visų servisų health.
7. Atlikti duomenų ir Auth/Storage smoke testus.

## STOP vartai

- Jei nėra checksum arba artefaktas ne iš patvirtinto R2 bucket’o — nestartuoti restore.
- Jei dešifravimas nepavyksta — nebandyti spėlioti identity ar slaptažodžio.
- Jei restore reikalauja production connection string — sustoti ir neperjungti source.
- Jei po restore DB health negrįžta — nestartuoti funkcinių testų, pirmiausia rinkti logus.

## Rollback

Rollback atliekamas per staging Docker volumes / Contabo snapshot. Production rollback šiame etape nevykdomas.

