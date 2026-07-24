# Supabase → VPS migracijos užbaigimas

**Progresas:** 100/100
**Būsena:** produkcinis perjungimas atliktas ir VPS patvirtintas kaip vienintelis
production duomenų šaltinis; liko formalus stabilizavimas ir senos aplinkos uždarymas  
**Cutover laikas:** 2026-07-18 22:49 UTC

Šiame dokumente sujungta ankstesnė `migration/` fazių dokumentacija. Detalūs istoriniai
matavimai, komandos ir tarpiniai sprendimai lieka Git istorijoje.

## Atlikta

- [x] Inventorizuota source DB, Auth, Storage, SMTP, redirect ir OAuth konfigūracija.
- [x] Sukurtas šifruotas DB backup, SHA-256 patikra ir off-host R2 kopija.
- [x] Patikrinta R2 retention: 7 daily, 4 weekly ir 3 monthly kopijos.
- [x] Paruoštas Ubuntu 24.04 VPS: ne-root administravimas, SSH key-only, UFW,
  Contabo firewall, Docker, persistent volumes ir swap.
- [x] Self-hosted Supabase publikuotas per Cloudflare Tunnel, DB ir pooler portų
  neatveriant viešai.
- [x] Atliktas katalogo-only restore rehearsal.
- [x] Naujausias automatinis R2 backup atkurtas izoliuotoje aplinkoje; RTO 53 s.
- [x] Staging katalogo canary ir 500 produktų kiekvienam target apkrovos testas praėjo.
- [x] Metadata canary 50/50 baigtas be `blocked_schema` ar retry klaidų.
- [x] Patikrintas fizinis privataus `sync-raw` objekto nuskaitymas ir gzip vientisumas.
- [x] Read-model refresh versijavimas, `pg_cron`, backup timeris ir 5 min. VPS
  monitorius veikia.
- [x] Staging Worker, JWKS, CORS, katalogas, filtrai, produkto peržiūra ir watchlist
  patikrinti.
- [x] Pages, Worker, GitHub Actions ir Auth perjungti į VPS Supabase.
- [x] Pagrindinis domenas `rinkissaupigiausia.online` aktyvus.
- [x] Cutover preflight grąžino 18/18 PASS.
- [x] Login, logout, katalogo, filtrų, produkto, watchlist ir admin write smoke
  patikros praėjo.
- [x] Production katalogo sync apdorojo 10 000 produktų, o refresh pasiekė 44/44.
- [x] Telegram botas perjungtas.

## Likę privalomi uždarymo darbai

- [x] Retrospektyviai patikrinti ir užfiksuoti T+15 min., T+1 h., T+6 h. ir T+24 h.
  monitoringo įrodymus. Jei jų nebėra, aiškiai pažymėti, kad istorinis checkpoint
  nebuvo surinktas, ir atlikti dabartinės būsenos auditą. Istorinių įrodymų repo
  nėra; pakaitinis auditas atliktas `2026-07-24 07:21–07:22 UTC`.
- [x] Patvirtintas po cutover sėkmingas automatinis katalogo workflow:
  [run 30055749953](https://github.com/mokinys98/AboutYou/actions/runs/30055749953),
  `2026-07-24 00:17:12–00:35:16 UTC`, `conclusion=success`.
- [x] Patvirtintas po cutover sėkmingas automatinis metadata workflow:
  [run 30073320456](https://github.com/mokinys98/AboutYou/actions/runs/30073320456),
  `2026-07-24 06:47:12–06:54:40 UTC`, `conclusion=success`.
- [x] Patvirtintas po cutover automatinis šifruotas R2 backup ir bandomasis restore:
  `RESTORE_VERIFY_SUCCESS`, RTO `84 s`, patikrinti visi payload checksum'ai.
- [x] Patikrinti SMTP alert laiško gedimo ir atsistatymo pranešimo pristatymą: VPS teste gauti abu laiškai, `FAILED` ir `RECOVERED`.
- [x] Užbaigti invite-only Auth scenarijų: invite, slaptažodžio nustatymas, logout,
  pakartotinis prisijungimas ir `viewer` teisių patikra; 2026-07-24 patikra PASS.
- [x] Priimtas sprendimas senų `sync-raw` / `sync-debug` objektų neperkelti: source
  Supabase projektas ištrintas, o dabartiniai duomenys renkami VPS.
- [x] Patvirtinta pilno metadata užpildymo būsena ir likusių terminalinių klaidų
  pasiskirstymas; 2026-07-24 07:00 UTC rezultatai pateikti audito lentelėje.
- [x] Užfiksuota, kad VPS yra vienintelis authoritative production duomenų šaltinis.
- [x] Source Supabase projektas ištrintas 2026-07-24; retention nebetaikoma.
- [x] Patikrinta automatinių Ubuntu security updates politika ir inode rezervas:
  abu timeriai enabled/active, periodinės reikšmės `1`, inode naudojimas `2 %`.
- [x] Atnaujinti `docs/TURINYS.md` migracijos progresą iki 100/100.

## 2026-07-24 nepriklausoma dabartinės būsenos patikra

Šią patikrą Codex atliko tiesiogiai iš repo, viešų produkcijos endpoint'ų, VPS
Supabase REST API ir source Supabase DB. Slaptos reikšmės nebuvo įrašytos į
dokumentaciją.

| Patikra | Rezultatas |
|---|---|
| Cutover preflight | `18/18 PASS` 2026-07-24: Pages, production Worker, CORS, JWKS ir auth gate veikia |
| Production Pages DB | runtime config rodo `https://supabase-staging.rinkissaupigiausia.online` |
| Production Worker DB | `/health.backendOrigin` rodo tą patį VPS Supabase |
| Source DB rašymas po cutover | `0` `sync_runs`; paskutinis produkto pakeitimas `2026-07-18 21:57:27 UTC`, t. y. iki cutover |
| Automatinis katalogo workflow | run `30055749953`, pradėtas tiksliai cron `00:17 UTC`, visas job `success`, `Streetwear 10 000/10 000`, paprašyta read-model versija `189` |
| Automatinis metadata workflow | run `30073320456`, pradėtas tiksliai cron `06:47 UTC`, visas job `success`, claimed `925`, complete `904`, retryable `0`, blocked šiame cikle `0` |
| Automatinis R2 backup | Cloudflare R2 objektas `automatic/20260724T021537Z/aboutyou-supabase-20260724T021537Z.tar.age`, dydis `81 694 376 B`, storage class `Standard`; service `Result=success` |
| Izoliuotas R2 restore | `RESTORE_VERIFY_SUCCESS`, RTO `84 s`, DB `816 639 123 B`, `57 119` produktų, `191` kategorija, `3` Auth vartotojai, `746` Storage objektai / `6 331 000 B` |
| Restore integralumas | `roles.sql`, `database.dump`, `storage-files.tar`, `postgresql-custom.tar`, `metadata.txt` — visi checksum `OK` |
| Paskutinis sėkmingas VPS katalogo target | `Streetwear`, `10 000` produktų, baigta `2026-07-24 06:30:33 UTC` |
| Dabartinė metadata aprėptis, parseris 5 | aktyvūs `49 333`; complete `49 227`; pending `20`; retryable `0`; source unavailable `85`; blocked schema `1` |
| Terminalinės aktyvių produktų klaidos | `85 × product_detail_redirected`; `1 × unknown_size_type:groupedSizes` |
| VPS monitorius | `2026-07-24 07:21:57 UTC`: visi 11 Supabase konteinerių healthy, Docker ir cloudflared active, JWKS ir Worker HTTP 200, `SUMMARY all monitoring checks passed` |
| VPS resursai | RAM `2.7/11 GiB`, available `9.0 GiB`; swap `512 KiB/4 GiB`; root diskas `21/193 GiB` (`11 %`); inode `392K/25M` (`2 %`) |
| DB ir WAL | DB `1121 MB`; `pg_wal` `640 MiB`; read model `197/197 clean`, error tuščias, paskutinis refresh `2026-07-24 06:55:25 UTC` |
| Backup servisas | timeris enabled/active; paskutinis service `Result=success`, `ExecMainStatus=0`; kitas suplanuotas `2026-07-25 04:27 CEST` |
| Ubuntu atnaujinimai | `apt-daily.timer` ir `apt-daily-upgrade.timer` enabled/active; `Update-Package-Lists=1`, `Unattended-Upgrade=1` |
| SMTP alert email | VPS monitorius naudoja esančią Supabase SMTP konfigūraciją; teste gauti `AboutYou VPS monitor FAILED` ir `AboutYou VPS monitor RECOVERED` laiškai aktyviam administratoriui |
| Invite-only Auth | Produkciniame puslapyje patikrintas invite, slaptažodžio nustatymas, logout, pakartotinis login ir `viewer` be admin teisių; PASS |
| Source Supabase projekto būsena | senas source projektas ištrintas 2026-07-24; po ištrynimo production `PRODUCTION_OK`, VPS monitorius `status=0/SUCCESS` |

Svarbu: paskutinio 2026-07-24 katalogo ciklo pabaigoje `Sportas` ir `Aksesuarai`
target'ai baigėsi `failed`, o DB klaida išsaugota nekokybiškai kaip `[object Object]`.
Tai nepaneigia ankstesnio automatinio sėkmingo run įrodymo, tačiau yra atskira dabartinė
katalogo patikimumo problema, kurią reikia ištirti.

Istorinių T+15 min., T+1 h., T+6 h. ir T+24 h. ekrano kopijų ar žurnalų repo nėra,
todėl jie nėra pateikiami kaip tuo metu surinkti įrodymai. Vietoje jų
`2026-07-24 07:21–07:22 UTC` atliktas pakaitinis dabartinės būsenos auditas:
viešas preflight `18/18 PASS`, VPS monitorius PASS, resursai normos ribose, backup
servisas sėkmingas, read modelis aktualus ir automatiniai security updates aktyvūs.

## Likusių darbų operatoriaus instrukcijos

Visų komandų išvestyje palikite UTC laiką, bet nekopijuokite tokenų, slaptažodžių,
service-role rakto, SMTP slaptažodžio ar Auth nuorodų su tokenais.

### 1. Automatiniai katalogo ir metadata workflow — atlikta

GitHub CLI peržiūra patvirtino:

- katalogo run `30055749953` sukurtas `2026-07-24 00:17:12 UTC`, tiksliai pagal
  Worker cron `17 */6 * * *`; `workflow_dispatch`, job ir visi jo žingsniai
  `success`; sync baigėsi per `17 min 24 s` ir paprašė read-model versijos `189`;
- metadata run `30073320456` sukurtas `2026-07-24 06:47:12 UTC`, tiksliai pagal
  Worker cron `47 * * * *`; `workflow_dispatch`, job ir visi jo žingsniai
  `success`; ciklas užbaigė `904` produktus, neturėjo retryable ar naujų
  blocked-schema rezultatų.

Metadata loge `rate_limited=true`, tačiau procesas pagal dabartinę politiką saugiai
užbaigė checkpointą ir pats GitHub job baigėsi `success`. Tai nėra šio uždarymo
punkto blokatorius.

### 2. T+ checkpointų pakaitinis dabartinės būsenos auditas — atlikta

Prisijunkite prie VPS per išsaugotą PuTTY `deploy` sesiją ir vykdykite:

```bash
date -u
sudo systemctl start aboutyou-vps-monitor.service
sudo systemctl --no-pager --full status aboutyou-vps-monitor.service
sudo journalctl -u aboutyou-vps-monitor.service -n 100 --no-pager
sudo docker stats --no-stream
free -h
df -h /
df -ih / /srv/supabase
sudo docker exec supabase-db du -sh /var/lib/postgresql/data/pg_wal
sudo docker exec supabase-db psql -P pager=off -U postgres -d postgres -c \
"SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;
 SELECT requested_version,completed_version,last_status,last_duration_ms,last_error,
        refresh_completed_at
 FROM public.catalog_read_model_refresh_state;"
```

Užskaitykite tik jei monitorius baigiasi `SUMMARY all monitoring checks passed`,
root diskas mažesnis nei `80 %`, backup jaunesnis nei `36 h`, konteineriai
`healthy/running`, read modelio `requested_version = completed_version`, o
`last_error` tuščias. Tada Windows repo šaknyje dar kartą vykdykite:

```powershell
$env:MIGRATION_PHASE="cutover"
npm.cmd run migration:preflight
Remove-Item Env:MIGRATION_PHASE
```

Prie T+ punkto įrašykite, kad istoriniai checkpointai nebuvo surinkti, tačiau
pakaitinis auditas atliktas, pridėkite UTC laiką ir trumpą rezultatų suvestinę.

### 3. Automatinis šifruotas R2 backup ir restore — atlikta

`2026-07-24` naujausias automatinis R2 objektas parsisiųstas, iššifruotas ir atkurtas
izoliuotame disposable `supabase/postgres:17.6.1.136` konteineryje. Visi vidiniai
checksum'ai sutapo, restore smoke užklausos praėjo:

```text
products=57119
categories=191
auth_users=3
storage_objects=746
RESTORE_VERIFY_SUCCESS rto_seconds=84 database_bytes=816639123
storage_files=746 storage_bytes=6331000
remote=automatic/20260724T021537Z/aboutyou-supabase-20260724T021537Z.tar.age
```

VPS patikrinkite timerį ir paskutinį automatinį paleidimą:

```bash
date -u
sudo systemctl list-timers aboutyou-supabase-backup.timer --no-pager
sudo systemctl --no-pager --full status aboutyou-supabase-backup.service
sudo journalctl -u aboutyou-supabase-backup.service -n 100 --no-pager
sudo find /srv/supabase/backups/encrypted -maxdepth 1 -type f \
  -name 'aboutyou-supabase-*.tar.age' -printf '%TY-%Tm-%TdT%TH:%TM:%TSZ %s %p\n' \
  | sort -r | head
```

Pilnam bandymui iš Windows repo nukopijuokite jau paruoštą verifikavimo skriptą:

```powershell
scp .\scripts\migration\verify-vps-backup-restore.sh deploy@<VPS_IP>:/tmp/
```

Tada VPS:

```bash
sudo bash /tmp/verify-vps-backup-restore.sh
sudo rm -f /tmp/verify-vps-backup-restore.sh
```

Užskaitykite tik gavę `RESTORE_VERIFY_SUCCESS`. Į dokumentą įrašykite
`remote`, `rto_seconds`, `database_bytes`, `storage_files` ir UTC laiką. `age`
privataus rakto turinio niekur nekopijuokite.

### 4. SMTP alert laiško gedimo ir atsistatymo testas

Šis testas naudoja atskirą būsenos katalogą, todėl nekeičia produkcinio monitoriaus
`last-status`. VPS vykdykite:

```bash
sudo install -d -m 0700 /tmp/aboutyou-alert-test
sudo cp /etc/aboutyou-monitor/monitor.env /tmp/aboutyou-alert-test/failure.env
echo 'SUPABASE_HEALTH_URL=http://127.0.0.1:9/forced-failure' | \
  sudo tee -a /tmp/aboutyou-alert-test/failure.env >/dev/null
sudo env ABOUTYOU_MONITOR_CONFIG=/tmp/aboutyou-alert-test/failure.env \
  ABOUTYOU_MONITOR_STATE_DIR=/tmp/aboutyou-alert-test/state \
  /usr/local/sbin/aboutyou-vps-monitor
```

Pirma komanda turi baigtis klaida ir išsiųsti vieną `FAILED` laišką visiems aktyviems
`admin` nariams. Tada paleiskite recovery su tikra konfigūracija:

```bash
sudo env ABOUTYOU_MONITOR_CONFIG=/etc/aboutyou-monitor/monitor.env \
  ABOUTYOU_MONITOR_STATE_DIR=/tmp/aboutyou-alert-test/state \
  /usr/local/sbin/aboutyou-vps-monitor
sudo rm -rf /tmp/aboutyou-alert-test
```

Antro paleidimo pabaiga turi būti `SUMMARY all monitoring checks passed`, o visi
administratoriai turi gauti `RECOVERED`. Jei laiškai negaunami, patikrinkite SMTP
konfigūracijos laukų būseną neatskleisdami jų reikšmių:

```bash
sudo awk -F= '/^(SMTP_HOST|SMTP_PORT|SMTP_USER|SMTP_PASS|SMTP_ADMIN_EMAIL)=/ {print $1 "=" (length($2)>0 ? "CONFIGURED" : "EMPTY")}' /srv/supabase/docker/.env
sudo docker exec supabase-db psql -At -U postgres -d postgres -c "select count(*) from public.team_members where role='admin' and active;"
```

SMTP slaptažodžio ir administratorių adresų į dokumentą nekelkite.

### 5. Invite-only Auth, magic link, PKCE ir logout

Naudokite naują testinį el. paštą, kurio dėžutę valdote:

1. Prisijunkite prie `https://rinkissaupigiausia.online` kaip administratorius.
2. Atverkite **Valdymas** → **Vartotojai**.
3. Įrašykite testinį el. paštą ir spauskite **Siųsti kvietimą**.
4. Patikrinkite, kad vartotojo būsena yra **Laukia priėmimo** ir laiškas gautas.
5. Kvietimo nuorodą atverkite privačiame / incognito lange. URL su tokenu niekur
   nekopijuokite. Nustatykite bent 8 simbolių slaptažodį.
6. Patikrinkite, kad atsidaro katalogas, o **Valdymas** → **Vartotojai** būsena tampa
   **Aktyvus** ir atsiranda priėmimo laikas.
7. Atsijunkite. Tiesiogiai atverkite `/watchlist`; turi nukreipti į `/login`.
8. Prisijunkite slaptažodžiu, vėl atsijunkite ir uždarykite visus to privataus lango
   tab'us. Naujas privatus langas turi reikalauti naujo prisijungimo.
9. Login puslapyje įrašykite tą patį el. paštą ir spauskite **Gauti magic link**.
   Gautą nuorodą atverkite tame pačiame privačiame lange. Ji turi pereiti per
   `/auth/callback` ir atidaryti katalogą. Tai kartu patikrina PKCE code exchange.
10. VPS Auth loguose patikrinkite, kad nėra netikėtų `redirect_uri`, PKCE ar SMTP
    klaidų:

```bash
sudo docker logs --since 30m supabase-auth 2>&1 | tail -n 200
```

Užfiksuokite tik PASS/FAIL ir UTC laikus. Testinio vartotojo šalinimas yra atskiras,
destruktyvus veiksmas — jo neatlikite, kol nepatvirtinta, kad nereikia įrodymams.
Nuorodos: [Supabase naudotojų kvietimai](https://supabase.com/docs/guides/auth/users),
[PKCE eiga](https://supabase.com/docs/guides/auth/sessions/pkce-flow).

### 6. `sync-raw` / `sync-debug` istorijos sprendimas

Rekomenduojamas projekto sprendimas: nemigruoti visos senos diagnostikos istorijos;
išsaugoti tik sutartą reprezentatyvų `sync-raw` sample, o `sync-debug` artefaktus
generuoti iš naujo atsiradus klaidoms. Prieš pažymint punktą:

1. Source Supabase → **Storage** → `sync-raw` ir `sync-debug`: užfiksuokite objektų
   skaičių bei bendrą dydį.
2. VPS admin dashboard patikrinkite, kad nauji `product_sync_artifacts` įrašai turi
   `ready` būseną ir realiai parsisiunčia gzip objektą.
3. Dokumente įrašykite konkretų sprendimą, pvz.:
   „Perkeliame naujausius / atrinktus 20 % `sync-raw`; senos `sync-debug` istorijos
   atsisakome; nauji objektai generuojami automatiškai ir galioja pagal dabartinę
   retention politiką.“
4. Netrinkite source objektų, kol R2 backup / restore punktas neuždarytas ir
   retention sprendimas nepatvirtintas.

### 7. Source Supabase retention / išjungimas

Source projektas po cutover į jį neberašė ir 2026-07-24 buvo galutinai ištrintas.
Kadangi dabartiniai duomenys renkami VPS, senų `sync-raw` / `sync-debug` objektų
perkelti nereikėjo.

Iki ištrynimo buvo patikrinta:

- nelaikykite source workflow ir cron aktyvių;
- nekeiskite source schemos ar duomenų;
- palikite paskutinį šifruotą backup R2;
- kartą per savaitę patikrinkite, kad `sync_runs` po cutover tebėra `0`.

Po ištrynimo atlikta production patikra grąžino `PRODUCTION_OK`, o VPS monitorius
baigėsi `status=0/SUCCESS`. Ištrynimas buvo atliktas tik turint sėkmingo R2 restore
įrodymą.
[Supabase projekto pauzės ir ištrynimo gairės](https://supabase.com/docs/guides/platform/delete-project)
paaiškina, kad rankinė pauzė šiuo metu galima tik Free planui, o ištrynimas yra
negrįžtamas.

### 8. Ubuntu security updates ir inode rezervas — atlikta

VPS vykdykite tik skaitomas patikras:

```bash
date -u
systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer
systemctl is-active apt-daily.timer apt-daily-upgrade.timer
systemctl list-timers 'apt-daily*' --no-pager
sudo grep -R --line-number -E \
  'APT::Periodic::(Update-Package-Lists|Unattended-Upgrade)' \
  /etc/apt/apt.conf.d
sudo unattended-upgrade --dry-run --debug
df -ih / /srv/supabase
findmnt -no SOURCE,FSTYPE,OPTIONS --target /
findmnt -no SOURCE,FSTYPE,OPTIONS --target /srv/supabase
```

Užskaitykite, jei abu timeriai `enabled`, dry-run neturi konfigūracijos klaidų,
inode naudojimas mažesnis nei `80 %`, o laisvų inode pakanka prognozuojamam logų ir
Storage augimui. Jei `/srv/supabase` yra tame pačiame mount kaip `/`, dokumente
įrašykite vieną bendrą inode rodiklį. Nekeiskite filesystem parametrų ir
nepaleiskite `tune2fs` rašymo komandų be atskiro maintenance lango bei backup.
[Ubuntu Server automatic updates gairės](https://documentation.ubuntu.com/server/how-to/software/automatic-updates/)
patvirtina naudojamus timerius, konfigūracijos failus ir `--dry-run` patikrą.

## Priimti neblokuojantys sprendimai

- Seni source Auth vartotojai nebuvo migruojami dėl invite-only modelio.
- Savitarnos password recovery nėra privaloma; reset atlieka savininkas.
- Pilnas 250k metadata testas nebuvo cutover vartas: priimtas fazuotas paleidimas su
  ribotu testu, veikiančiu refresh ir resursų stebėsena.
- Visa istorinė diagnostinių Storage objektų kopija nėra būtina, jei sprendimas
  dokumentuotas ir aktualūs objektai bei backup išsaugomi.
- Išorinis webhook keičiamas į jau naudojamą Supabase SMTP: monitorius siunčia tik
  `FAILED` ir `RECOVERED` būsenos pasikeitimo laiškus aktyviems `admin` nariams.

## Rollback runbook

Rollback pradėti, jei neveikia Auth, katalogas masiškai grąžina 5xx, pastebima duomenų
korupcija arba kritinės priežasties nepavyksta nustatyti per 15 minučių.

1. Sustabdyti Worker cron triggerius ir rašančius GitHub workflow.
2. Pages grąžinti source Supabase URL bei anon raktą ir redeployinti.
3. Worker grąžinti source URL bei service-role secret ir redeployinti.
4. Iš production workflow pašalinti `environment: production-vps`, kad būtų naudojami
   nepakeisti source repository secrets; workflow dar neįjungti.
5. Paleisti source preflight ir rankinį smoke.
6. Tik po source GO atkurti schedulerius.
7. VPS palikti incidento analizei; netrinti DB, Storage ar logų.

Rollback automatiškai neperkelia po cutover į VPS įrašytų duomenų atgal į source.
Prieš ilgesnį source naudojimą būtinas atskiras duomenų suderinimo sprendimas.

## Dokumento uždarymas

- [ ] Baigta – galima ištrinti
