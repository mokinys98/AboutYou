# 2 fazė — pirmas restore rehearsal

## Naujausias checkpoint (2026-07-16)

- [x] `data.public.sql` sugeneruotas iÅ¡ `data.sql`, dydis 290,185,795 B.
- [x] Validuoti 29 `COPY "public".*` blokai; Auth neatitikimo blokai neÄ¯traukti.
- [x] Vykdyti `public` duomenÅ³ importÄ… ir row-count smoke testÄ….
- [ ] IÅ¡sprÄ™sti Auth/Storage schemÅ³ parity; tai likÄ™s atskiru restore vartÅ³ darbu.
- [x] Pirmas public importas sustojo ties `team_members_user_id_fkey`, nes `auth.users` dar neatkurtas; nusprÄ™sta atskirti nuo Auth priklausanÄias lenteles.
- [x] Sprendimas: staging restore gali bÅ«ti katalogo-only; source Auth vartotojai nemigruojami, staging naudotojas kuriamas naujai per Supabase Auth.
- [x] Katalogo-only likutis importuotas sÄ—kmingai (`data.catalog.final.sql`); Auth ir vartotojÅ³ priklausomos lentelÄ—s sÄ…moningai praleistos.
- [x] Katalogo row-count smoke testas sutampa su source: products 51,535; offers 51,535; categories 190; daily_prices 220,101; product_size_options 294,806; sync_runs 604; sources 1.
- [x] Visi staging servisai paleisti ir `healthy`; Tunnel E2E grÄ…Å¾ina HTTP 401 (Kong/Auth pasiekiamas ir reikalauja autentifikacijos).
- [x] Po importo perskaiÄiuotas materializuotas katalogo read model (`public.catalog_items_read`); API rodo atkurtus produktus.
- [x] `public.catalog_items_read` perskaiÄiuotas po restore; aplikacijoje produktai rodomi.
- [x] `public.catalog_item_facet_values_read` ir `catalog_facets_cache` perskaiÄiuoti; `catalog_items_read` turi 48,446 paruoÅ¡tus katalogo Ä¯raÅ¡us.
- [x] Lokalus web login ir katalogo pagrindinio puslapio smoke testas sÄ—kmingas; staging API naudoja naujÄ… Auth vartotojÄ….
- [x] Studio dashboard expose'intas tik per `127.0.0.1:3000`; vieÅ¡ai nepublikuotas, prieiga numatyta per SSH local port-forward.

## Progreso blokas

- [x] Staging Supabase stack paleistas ir visi servisai healthy.
- [x] Staging API pasiekiamas per Cloudflare Tunnel.
- [x] Į VPS saugiai pristatytas pasirinktas source dump artefaktas iš R2.
- [x] Sukurtas restore rehearsal darbo katalogas su `0700` teisėmis.
- [x] VPS įdiegti `age 1.1.1` ir `rclone 1.60.1`; R2 secret failas rastas `/etc/aboutyou-backup/r2.env` su `0600` teisėmis.
- [x] R2 read-only connectivity testas sėkmingas; matomas baseline prefiksas.
- [x] Baseline prefikso artefaktas pasirinktas: `aboutyou-supabase-20260715T192442Z.tar.gz.age`, `48,710,800 B`.
- [x] Artefaktas atsisiųstas į VPS ir SHA-256 sutampa su 0 fazės manifestu.
- [x] Dump parašas / checksum patikrintas prieš dešifravimą.
- [x] Source dump iššifruotas naudojant VPS age identity; private key į logus nepatenka.
- [x] Age identity saugiai pristatyta į `/etc/aboutyou-backup/age-identity`; formatas validus, teisės `0600`.
- [x] Iššifruoto `tar.gz` SHA-256 sutampa su 0 fazės manifestu.
- [x] `tar.gz` įrašų skaičius ir tar/gzip integralumas papildomai patikrinti; archyve yra `roles.sql`, `schema.sql`, `data.sql`.
- [x] Išskleisti failai atskirame restore kataloge; dydžiai sutampa su source manifestu.
- [x] Dump antraštės patikrintos: roles koreguoja esamas roles, schema naudoja `IF NOT EXISTS`, data paruošta importui.
- [ ] Atkurtos roles, schema ir data į staging DB.
- [x] Roles ir schema importai sėkmingi.
- [x] Katalogo-only data importas baigtas; pirmas bandymas sustojo dėl source/target Auth schemos neatitikimo (`auth.custom_oauth_providers.custom_claims_allowlist`).
- [x] Dėl Auth schemos versijų skirtumo paruoštas ir įvykdytas atskiras `public` aplikacijos duomenų importas; Auth/Storage parity lieka atskiru vartų darbu.
- [x] `public` importas validuotas pagal COPY targetus ir paruoštas vykdymui.
- [x] Atlikti katalogo row-count ir pagrindinių web/API smoke testai; Auth/Storage parity dar neatlikta.
- [ ] Užfiksuotas restore laikas, klaidos, duomenų dydis ir rollback pastabos.

**Būsena:** katalogo-only restore rehearsal atliktas staging aplinkoje: dump patikrintas ir iššifruotas, roles/schema importai sėkmingi, `public` katalogo duomenys atkurti, row-count ir web/API smoke testai sėkmingi. Pilnas Auth/Storage parity ir galutinis restore vartų uždarymas dar nebaigti; produkcinis Supabase ir production refresh šiame etape neliečiami.

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
5. Patikrinti dump antraštes ir staging DB sustabdymo / restore procedūrą parinkti pagal dump tipą.
6. Paleisti stack ir patikrinti visų servisų health.
7. Atlikti duomenų ir Auth/Storage smoke testus.

## STOP vartai

- Jei nėra checksum arba artefaktas ne iš patvirtinto R2 bucket’o — nestartuoti restore.
- Jei dešifravimas nepavyksta — nebandyti spėlioti identity ar slaptažodžio.
- Jei restore reikalauja production connection string — sustoti ir neperjungti source.
- Jei po restore DB health negrįžta — nestartuoti funkcinių testų, pirmiausia rinkti logus.

Restore incident checkpoint: po roles/schema sėkmės data importas sustojo ties `auth.custom_oauth_providers.custom_claims_allowlist`. Aplikaciniai servisai palikti sustabdyti; prieš tęsiant reikia suderinti Auth schemų versijas arba atskirti Auth duomenų sekciją nuo public aplikacijos duomenų.

## Rollback

Rollback atliekamas per staging Docker volumes / Contabo snapshot. Production rollback šiame etape nevykdomas.
