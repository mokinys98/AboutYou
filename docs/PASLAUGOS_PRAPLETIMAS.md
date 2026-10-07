# Paslaugos praplėtimas: VPS stebėsena

**Būsena:** VPS inventorizacija pateikta. Paruošta atskira Prometheus, Grafana ir Node Exporter konfigūracija su 3 dienų metrikų saugojimu ir privačia prieiga; VPS diegimas dar neatliktas. Pakartotinis `docker system df` pavyko; ankstesnė klaida buvo laikina.

## Ką radome

Pagal 2026-10-07 naudotojo PuTTY terminalo išvestį VPS veikia Ubuntu 24.04.4 LTS, branduolys `6.8.0-142-generic` (`x86_64`), yra 6 CPU. Atminties yra 11 GiB (9 GiB available), 4 GiB swap neužimta. `/` ir `/srv` yra tame pačiame `ext4` faile: 193 GB, iš jų 163 GB laisva (16 % panaudota).

Įdiegtos Docker Engine versija `29.6.2` ir Docker Compose `v5.3.1`. `docker ps` išvestyje matyti 11 Supabase konteinerių, visi `healthy`; Compose projekto darbo katalogas – `/srv/supabase/docker`.

- Pagrindinis Compose failas: `/srv/supabase/docker/docker-compose.yml`.
- Aktyvus papildomas failas: `docker-compose.staging.yml`.
- Studio konteineriui papildomai taikomas `docker-compose.studio-ssh.yml`.
- Tarp konteinerių yra `supabase-db`, būsena `healthy`, konteinerio prievadas `5432/tcp`.
- Iš pateiktos išvesties matyti, kad DB yra šiame VPS; tai nėra Supabase Cloud DB. Todėl hosto stebėsena tame pačiame VPS rodys ir DB serverio naudojamus CPU, RAM bei disko resursus.
- Hosto klausymuose SSH `22` pasiekiamas IPv4 ir IPv6 visose sąsajose. `8000`, `3000` ir `8443` klausa tik `127.0.0.1`; taip pat matomi lokalūs DNS `53` ir `20241` prievadai.
- UFW aktyvi; numatytoji įeinančio srauto politika `deny`, išeinančio `allow`, maršrutizuojamo `deny`. Matoma `22/tcp` `LIMIT IN` taisyklė IPv4 ir IPv6. `firewall-cmd` neįdiegtas, todėl `firewalld` būsena šia komanda nepatikrinta. VPS tiekėjo išorinės ugniasienės taisyklės nebuvo pateiktos.
- `docker system df` nepateikė saugyklos statistikos: daemon klaida nurodė, kad overlayfs snapshotter `Usage` negali rasti kelio po `/var/lib/containerd/.../snapshots/.../fs/tmp/`. Šiuos Docker saugyklos duomenis reikia diagnozuoti prieš jais remiantis; ši inventorizacija nieko netaisė ir konteinerių nekeičia.
- `journalctl` patvirtino tą pačią `docker system df` klaidą 2026-10-07 11:40 CEST. Taip pat yra `aboutyou-supabase-backup.timer` ir `aboutyou-vps-monitor.timer`; jų service aprašai ir tikrasis veikimas dar nepatikrinti. `crontab -l` grąžino `no crontab for root`. Kiti matomi timeriai daugiausia yra Ubuntu priežiūros užduotys.
- Peržiūrėti abiejų pasirinktinių systemd timerių ir service vienetų aprašai. Kopijų timeris vykdomas kasdien apie 02:15 UTC su iki 15 min. atsitiktiniu vėlavimu; jo service paleidžia `/usr/local/sbin/aboutyou-supabase-backup`, apraše nurodytas šifruotas siuntimas į Cloudflare R2, rašymas į `/srv/supabase/backups`. VPS monitoriaus timeris paleidžiamas po įkrovos ir vėliau kas 5 min. su iki 30 s. vėlavimu; service paleidžia `/usr/local/sbin/aboutyou-vps-monitor`, jam leidžiama rašyti į `/var/lib/aboutyou-monitor`.
- Pagal pateiktą VPS monitoriaus skriptą jis tikrina disko užimtumo slenkstį, Docker ir cloudflared paslaugas, 11 Supabase konteinerių būseną/sveikatą, du HTTP endpoint’us, kopijų timerį bei paskutinio vietinio šifruoto archyvo amžių, katalogo atnaujinimo būseną ir cron darbus. Būseną įrašo į `/var/lib/aboutyou-monitor/last-status`, o el. pašto perspėjimą siunčia tik pereinant į `failed` arba atsistačius. Tai periodiniai sveikatos testai, ne laiko eilučių metrikų saugykla: skriptas nerenka CPU/RAM/disko I/O grafiko ir atskirų konteinerių resursų istorijos. `SMTP_PASSWORD` ima iš konfigūracijos arba Supabase `.env`; naudotojas jokių slaptų reikšmių nepateikė.
- Monitoriaus konfigūracijoje nustatyta `DISK_MAX_PERCENT=80`, `BACKUP_MAX_AGE_SECONDS=129600` (36 val.) ir `READ_MODEL_PENDING_MAX_AGE_SECONDS=900` (15 min.). Abu HTTP sveikatos tikrinimo URL’ai nukreipia į staging aplinką.
- Naudotojas patikrino, kad `/srv/monitoring` dar nėra, o `3001` ir `9090` hosto prievadai neklausomi. Grafana gali naudoti `127.0.0.1:3001`, Prometheus – `127.0.0.1:9090`; esamas Supabase Studio lieka `127.0.0.1:3000`.
- `docker info` nurodo `overlayfs` saugyklos tvarkyklę ir `/var/lib/docker` šakninį katalogą. `docker ps -a` rodo 11 veikiančių Supabase konteinerių, tarp jų ir klaidos ID `132da…` konteinerį `supabase-kong`; papildomai yra `created` būsenos `aboutyou-restore-20260718t214312z` konteineris. Pakartotinis `docker system df` pavyko: 13 image (9.341 GB), 12 container (278 MB), 2 volume (509.3 kB); Docker saugyklos diagnostika užbaigta be remonto ar šalinimo.
- Stebėsenos konfigūracijos failai perkelti į `/srv/monitoring` ir priklauso `root:root`; `.env` failo režimas patvirtintas kaip `600`. Naudotojo slaptažodis nepateiktas pokalbyje; konteineriai nepaleisti.
- Pagal pateiktą `/usr/local/sbin/aboutyou-supabase-backup` skriptą kopija apima Postgres roles, `postgres` DB dump, fizinius Supabase Storage failus, Postgres custom konfigūraciją / pgsodium raktų medžiagą ir metaduomenis. Skriptas šifruoja `age` gavėjui, įkelia privatų objektą į Cloudflare R2 ir patikrina lokalaus bei nuotolinio objekto dydį. Lokalių `.tar.age` failų retention yra `LOCAL_RETENTION_DAYS`, numatytoji reikšmė 3 dienos; R2 trynimo / lifecycle taisyklės pačiame skripte nėra. Skriptas neapima `/srv/monitoring` ar Prometheus duomenų. Tikroji R2 lifecycle konfigūracija ir atkūrimo procedūros išbandymas dar nepatikrinti.

Šie faktai patikrinti pagal naudotojo pateiktą komandų išvestį, o ne tiesiogiai prisijungus prie VPS.

## Siūlomas stebėsenos rinkinys

- **Node Exporter** – VPS operacinės sistemos ir aparatinės įrangos metrikos: CPU naudojimas ir load average, RAM, swap, failų sistemos vieta ir diskų I/O statistika. [Oficialus vadovas](https://prometheus.io/docs/guides/node-exporter/).
- **Prometheus** – metrikų surinkimas ir istorijos saugojimas.
- **Grafana** – dashboard’ai ir vizualizacijos.
- **Postgres Exporter** – pasirinktinai PostgreSQL veikimo metrikoms, tokioms kaip jungtys ir DB statistika. Jis nepakeičia Node Exporter ir nerodo fizinio hosto CPU, RAM ar disko apkrovos. [Projektas ir dokumentacija](https://github.com/prometheus-community/postgres_exporter).
- **cAdvisor** – svarstyti, jei reikia atskirų Docker konteinerių resursų metrikų, o ne tik viso VPS apkrovos.

Pradiniam etapui pasirinktas hosto resursų stebėjimas su Prometheus, Grafana ir Node Exporter. Grafana ir Prometheus pririšami prie `127.0.0.1` ir pasiekiami per SSH tunelį; Node Exporter prievadas nepublikuojamas. Prometheus metrikų saugojimas – 3 dienos ir iki 2 GB; šių metrikų kopijos nedaromos, praradus diską istorija bus renkama iš naujo. Postgres Exporter ir cAdvisor dabar neįtraukiami.

Konfigūracijos failai paruošti [`ops/monitoring/`](../ops/monitoring/) kataloge. Naudojamos versijos: Prometheus `3.14.0`, Grafana `13.2.1`, Node Exporter `1.12.1`.

Kol kas nė vienas iš šių komponentų neįdiegtas ar nesukonfigūruotas šio darbo metu.

## Dar nepatikrinta

- Kaip šiuo metu daromos ir atkuriamos Docker duomenų atsarginės kopijos, įskaitant ar stebėsenos katalogas būtų įtrauktas į esamą procesą.
- Cloudflare R2 bucket lifecycle / retention taisyklė ir išbandyta Supabase kopijos atkūrimo procedūra.
- VPS tiekėjo išorinės ugniasienės taisyklės ir esama HTTPS / reverse proxy konfigūracija.
- VPS tiekėjo išorinės ugniasienės taisyklės (nors eksporterių ir UI prievadai lokaliai apribojami).
- `docker system df` klaidos priežastis ir patikima Docker saugyklos užimtumo statistika.

Serverio konfigūracija, konteineriai, ugniasienė ir prievadai nebuvo keisti. Stebėsenos įrankių diegimas neatliktas.

## Įgyvendinimo etapai

- [x] **Inventorizacija:** pagal naudotojo pateiktą terminalo išvestį patikrinti OS, Docker ir Compose versijas, VPS resursus, failų sistemos vietą, klausomus prievadus ir vietinę UFW būseną. `docker system df` klaida užfiksuota, jos statistika nepatvirtinta.
- [x] **Saugyklos diagnostika:** pakartotinis `docker system df` pavyko; ankstesnė klaida buvo laikina.
- [x] **Architektūra:** atskiras Compose projektas kataloge `/srv/monitoring`, atskirtas nuo `/srv/supabase/docker`.
- [x] **Prieigos apsauga:** Grafana `127.0.0.1:3001`, Prometheus `127.0.0.1:9090` ir SSH tunelis; Node Exporter prievadas nepublikuojamas.
- [x] **Saugojimas:** Prometheus 3 dienų retention, iki 2 GB; metrikų kopijos nedaromos, jas galima surinkti iš naujo.
- [x] **Konfigūracijos paruošimas:** Compose, Prometheus scrape ir Grafana duomenų šaltinio konfigūracijos paruoštos `ops/monitoring/` kataloge.
- [ ] **Diegimas:** konfigūracijos failus perkelti į VPS ir paleisti atskirą projektą. Prieš paleidimą diagnozuoti Docker daemon `system df` klaidą; VPS pakeitimai kol kas neatlikti.
- [ ] **Priėmimas:** patikrinti metrikų surinkimą, Grafana dashboard’us, alertus, privačią prieigą ir atsarginės kopijos atkūrimą.

## Darbų įrašas

### 2026-10-07 12:40 (Europe/Vilnius)

- Užfiksuoti pateikti OS, Docker/Compose, resursų, failų sistemos, klausomų prievadų ir UFW inventorizacijos faktai.
- Pažymėta `docker system df` overlayfs snapshotter klaida; jos priežastis dar nenustatyta. Atsarginių kopijų politika, išorinė ugniasienė ir Prometheus saugojimo pasirinkimai lieka nepatikrinti.
- VPS pakeitimai ar stebėsenos diegimas neatlikti.

### 2026-10-07 12:45 (Europe/Vilnius)

- `journalctl` išvestyje pakartotinai užfiksuota `docker system df` overlayfs `snapshotter.Usage` klaida; remonto veiksmai neatlikti.
- `systemctl list-timers` išvestyje aptikti `aboutyou-supabase-backup.timer` ir `aboutyou-vps-monitor.timer`; jų service konfigūracija dar turi būti peržiūrėta. Root naudotojui crontab nėra.
- Atsarginių kopijų realizacija ir stebėsenos timerio funkcija dar nepatvirtintos; VPS pakeitimai neatlikti.

### 2026-10-07 12:50 (Europe/Vilnius)

- Pagal naudotojo pateiktus systemd vienetų aprašus patvirtinta, kad kasdien vykdomos šifruotos Supabase atsarginės kopijos į Cloudflare R2 ir kas 5 min. paleidžiamas esamas VPS/Supabase monitorius.
- Užfiksuoti vykdomų skriptų keliai ir leidžiami rašymo katalogai. Skriptų turinys, metrikų aprėptis, kopijų retention ir atkūrimas dar nepatikrinti.
- VPS pakeitimai neatlikti; papildomas Prometheus/Grafana diegimas dar neparuoštas.

### 2026-10-07 12:55 (Europe/Vilnius)

- Pagal naudotojo pateiktą `/usr/local/sbin/aboutyou-vps-monitor` turinį užfiksuota esamų sveikatos patikrų aprėptis ir būsenos failo vieta.
- Nustatyta, kad dabartinis monitorius neteikia CPU, RAM, disko I/O ar konteinerių resursų laiko eilučių istorijos; Prometheus/Node Exporter vis dar pridėtų naują funkciją, ne dubliuotų šį grafikinį stebėjimą.
- Atsarginių kopijų skriptas, retention ir atkūrimas lieka nepatikrinti; diegimas ir VPS pakeitimai neatlikti.

### 2026-10-07 13:00 (Europe/Vilnius)

- Pagal pateiktą kopijų skriptą užfiksuota kopijos apimtis (Postgres, Storage, custom konfigūracija ir metaduomenys), `age` šifravimas, R2 įkėlimas ir dydžio patikra.
- Vietinių kopijų retention numatytas per `LOCAL_RETENTION_DAYS` (numatyta 3 dienos); R2 lifecycle iš skripto nenustatomas. Esamas backup skriptas Prometheus duomenų neapima.
- R2 retention ir atkūrimo procedūra dar nepatikrinti; stebėsenos diegimas neatliktas.

### 2026-10-07 13:10 (Europe/Vilnius)

- Patvirtinta, kad `/srv/monitoring` nėra, o planuoti Grafana/Prometheus hosto prievadai laisvi.
- Paruoštas atskiras Compose rinkinys su Prometheus, Grafana ir Node Exporter; Grafana ir Prometheus apriboti `127.0.0.1`, metrikų saugojimas nustatytas 3 dienoms / 2 GB.
- Konfigūracija paruošta lokaliai `ops/monitoring/`; į VPS neperkelta. Prieš diegimą lieka Docker daemon diagnostika.

### 2026-10-07 13:15 (Europe/Vilnius)

- `docker info` ir `docker ps -a` patvirtino `overlayfs`, visų esamų konteinerių veikimą ir sutapimą tarp klaidos ID bei `supabase-kong` konteinerio.
- Trūkstamas `resty_…` kelias yra laikinasis failas `supabase-kong` `/tmp`; tikėtina trumpalaikė `docker system df` apskaitos lenktyniavimo sąlyga, tačiau reikia vieno read-only pakartojimo.
- Aptiktas `created` būsenos `aboutyou-restore-20260718t214312z` konteineris; jis nekeistas. Stebėsenos failai dar neperkelti į VPS.

### 2026-10-07 13:20 (Europe/Vilnius)

- Pakartotinis `docker system df` pavyko ir pateikė Docker image, container bei volume suvestinę; remonto ar valymo nereikėjo.
- Ankstesnė overlayfs trūkstamo `supabase-kong` `/tmp/resty_…` kelio klaida laikoma laikina; steko diegimui Docker saugyklos statistika dabar prieinama.

### 2026-10-07 13:25 (Europe/Vilnius)

- Naudotojas per WinSCP įkėlė konfigūraciją į `/home/deploy/monitoring`; failai nukopijuoti į `/srv/monitoring` ir priskirti `root:root`.
- `.env` su Grafana administratoriaus slaptažodžiu dar nesukurtas; Compose konfigūracija neįjungta, konteineriai nepaleisti.

### 2026-10-07 13:30 (Europe/Vilnius)

- `.env` sukurtas root teisėmis, `stat` parodė `600`; slaptažodžio reikšmė nebuvo atskleista.
- `docker compose -f compose.yaml config -q` pavyko (`exit=0`), todėl Compose sintaksė ir privalomi kintamieji patikrinti. Vaizdai dar neatsisiųsti, stekas nepaleistas.

### 2026-10-07 13:35 (Europe/Vilnius)

- Naudotojas patvirtino, kad Prometheus, Grafana ir Node Exporter Docker vaizdai atsisiuntė sėkmingai. Konteineriai dar nepaleisti.

### 2026-10-07 13:40 (Europe/Vilnius)

- Naudotojas pranešė, kad visi trys stebėsenos konteineriai paleisti. Būsenos, scrape target’ų ir privačios prieigos priėmimas dar neatliktas.

### 2026-10-07 13:45 (Europe/Vilnius)

- `docker compose ps` patvirtino visus tris konteinerius `Up`: Grafana, Prometheus ir Node Exporter. Grafana ir Prometheus paskelbti tik `127.0.0.1:3001` ir `127.0.0.1:9090`; Node Exporter turi tik Compose tinklo prievadą `9100/tcp` be hosto prievado publikavimo.
- HTTP būklė, Prometheus aktyvių scrape target’ų būklė ir SSH tunelio prisijungimas dar tikrinami.

### 2026-10-07 13:50 (Europe/Vilnius)

- Grafana `13.2.1` health endpoint pateikė `database: ok`; Prometheus pateikė `Prometheus Server is Healthy.`
- Prometheus aktyvūs target’ai `node-exporter:9100` ir `prometheus:9090` abu turi `health=up`.
- SSH tunelis, prisijungimas Grafana UI ir hosto dashboard’as dar nesukonfigūruoti / nepatikrinti.

### 2026-10-07 12:38 (Europe/Vilnius)

- Pagal naudotojo PuTTY išvestį užfiksuotas `supabase` Compose projektas su 11 veikiančių konteinerių ir vietiniu `supabase-db`.
- Aprašytas siūlomas Prometheus, Node Exporter ir Grafana rinkinys bei pasirinktiniai PostgreSQL ir konteinerių exporter’iai.
- VPS būklė užfiksuota pagal pateiktą išvestį; stebėsenos konfigūracija dar neparuošta ir VPS pakeitimai neatlikti.
