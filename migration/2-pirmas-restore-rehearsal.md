# 2 fazė — pirmas restore rehearsal

## Progreso varnelės — atnaujinti pirmiausia

- [x] `data.public.sql` sugeneruotas iš `data.sql`, dydis 290,185,795 B.
- [x] Validuoti 29 `COPY "public".*` blokai; Auth neatitikimo blokai neįtraukti.
- [x] `public` katalogo duomenų importas ir row-count smoke testas atlikti.
- [x] Patvirtintas invite-only Auth sprendimas: source Auth vartotojai nemigruojami, staging/target vartotojai kuriami ir kviečiami naujai.
- [x] Pirmas importas sustojo ties `team_members_user_id_fkey`; priežastis identifikuota kaip sąmoningai neatkurtas `auth.users`, todėl nuo Auth priklausomi duomenys atskirti.
- [x] Katalogo-only restore pasirinktas kaip šio rehearsal apimtis; Auth schemos versijų neatitikimas neapeinamas pavojingu SQL taisymu.
- [x] Katalogo-only likutis importuotas sėkmingai (`data.catalog.final.sql`); Auth ir vartotojų priklausomos lentelės sąmoningai praleistos.
- [x] Katalogo row-count smoke testas sutampa su source: products 51,535; offers 51,535; categories 190; daily_prices 220,101; product_size_options 294,806; sync_runs 604; sources 1.
- [x] Visi staging servisai paleisti ir `healthy`; Tunnel E2E grąžina HTTP 401 (Kong/Auth pasiekiamas ir reikalauja autentifikacijos).
- [x] Po importo perskaičiuotas materializuotas katalogo read model (`public.catalog_items_read`); API rodo atkurtus produktus.
- [x] `public.catalog_items_read` perskaičiuotas po restore; aplikacijoje produktai rodomi.
- [x] `public.catalog_item_facet_values_read` ir `catalog_facets_cache` perskaičiuoti; `catalog_items_read` turi 48 446 paruoštus katalogo įrašus.
- [x] Lokalus web login ir katalogo pagrindinio puslapio smoke testas sėkmingas; staging API naudoja naują Auth vartotoją.
- [x] Studio dashboard publikuotas tik per `127.0.0.1:3000`; viešai nepasiekiamas, prieiga numatyta per SSH local port-forward.

## Progreso blokas

- [x] Staging Supabase stack paleistas ir visi servisai healthy.
- [x] Staging API pasiekiamas per Cloudflare Tunnel.
- [x] Į VPS saugiai pristatytas pasirinktas source dump artefaktas iš R2.
- [x] Sukurtas restore rehearsal darbo katalogas su `0700` teisėmis.
- [x] VPS įdiegti `age 1.1.1` ir `rclone 1.60.1`; R2 secret failas rastas `/etc/aboutyou-backup/r2.env` su `0600` teisėmis.
- [x] R2 read-only connectivity testas sėkmingas; matomas baseline prefiksas.
- [x] Baseline prefikso artefaktas pasirinktas: `aboutyou-supabase-20260715T192442Z.tar.gz.age`, `48,710,800 B`.
- [x] Artefaktas atsisiųstas į VPS ir SHA-256 sutampa su 0 fazės manifestu.
- [x] Dump checksum patikrintas prieš dešifravimą.
- [x] Source dump iššifruotas naudojant VPS age identity; private key į logus nepateko.
- [x] Age identity saugiai pristatyta į `/etc/aboutyou-backup/age-identity`; formatas validus, teisės `0600`.
- [x] Iššifruoto `tar.gz` SHA-256 sutampa su 0 fazės manifestu.
- [x] `tar.gz` įrašų skaičius ir tar/gzip integralumas papildomai patikrinti; archyve yra `roles.sql`, `schema.sql`, `data.sql`.
- [x] Išskleisti failai atskirame restore kataloge; dydžiai sutampa su source manifestu.
- [x] Dump antraštės patikrintos: roles koreguoja esamas roles, schema naudoja `IF NOT EXISTS`, data paruošta importui.
- [x] Atkurtos roles, schema ir katalogo duomenys; source Auth vartotojai ir nuo jų priklausomi įrašai sąmoningai neimportuoti.
- [x] Roles ir schema importai sėkmingi.
- [x] Katalogo-only data importas baigtas; pirmo bandymo Auth schemos neatitikimas (`auth.custom_oauth_providers.custom_claims_allowlist`) užfiksuotas kaip priežastis nemigruoti source Auth duomenų.
- [x] Paruoštas ir įvykdytas atskiras `public` katalogo duomenų importas.
- [x] `public` importas validuotas pagal COPY targetus.
- [x] Atlikti katalogo row-count ir pagrindiniai web/API smoke testai.
- [x] Užfiksuotos pagrindinės restore klaidos, dump ir išskleistų failų dydžiai bei katalogo-only sprendimas.
- [ ] Perkelti ir palyginti fizinius `sync-raw` bei `sync-debug` Storage objektus pagal count, bytes ir atrinktus hash/ETag.
- [x] Atliktas disposable restore iš naujausio automatinio R2 backup: DB, roles, Storage ir Postgres custom/pgsodium payload patikrinti, `RESTORE_VERIFY_SUCCESS`, RTO `53 s` (2026-07-19).

**Būsena:** katalogo-only restore rehearsal staging aplinkoje atliktas, o naujausias automatinis R2 backup papildomai pilnai atkurtas disposable aplinkoje per `53 s`: DB, roles, vienas fizinis Storage objektas ir Postgres custom/pgsodium medžiaga patikrinti. Source Auth vartotojai pagal patvirtintą invite-only sprendimą nemigruojami — target vartotojai kviečiami naujai. Fazės likutis yra tik formaliai priimti istorinių `sync-raw` / `sync-debug` objektų parity arba atsisakymo sprendimą. Produkcinis Supabase šiame etape nekeistas.

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

Istorinis restore incident checkpoint: po roles/schema sėkmės pirmas data importas sustojo ties `auth.custom_oauth_providers.custom_claims_allowlist`. Incidentas uždarytas pasirinkus katalogo-only restore: Auth duomenų sekcija atskirta, source vartotojai nemigruojami, o staging servisai vėliau paleisti ir patikrinti.

## Rollback

Rollback atliekamas per staging Docker volumes / Contabo snapshot. Production rollback šiame etape nevykdomas.
