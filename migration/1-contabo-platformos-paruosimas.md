# 1 fazė — Contabo platformos paruošimas

## Progreso varnelės — atnaujinti pirmiausia

- [x] Contabo VPS sukurtas.
- [x] VPS OS patvirtinta: Ubuntu 24.04 LTS.
- [x] VPS read-only preflight atliktas; viešų Supabase portų nerasta.
- [x] Sukurtas ne-root administratorius ir patikrintos `sudo` teisės (`sudo -v` sėkmingas); SSH key-only režimas patvirtintas žurnale.
- [x] Ubuntu paketų atnaujinimai ir hardening paketų diegimas atlikti.
- [x] Nauja PuTTY sesija su `deploy` ir `.ppk` naudota; žurnale patvirtinta `Accepted publickey`.
- [x] SSH hardening konfigūracija pritaikyta ir end-to-end patikrinta nauja PuTTY key-only sesija (`deploy` + teisingas `.ppk`).
- [x] Įjungtas UFW deny-by-default; SSH `22/tcp` nustatytas `LIMIT` IPv4 ir IPv6.
- [x] Contabo firewall deny-by-default profilis priskirtas VPS; `ACCEPT TCP 22` ir `DROP Any/Any` taisyklės aktyvios.
- [x] Cloudflare nameserverių propagacija baigta; domenas rodo `protected by Cloudflare`.
- [x] Atliktas kontroliuojamas VPS reboot ir post-reboot patikra.
- [ ] Įdiegtas Docker Engine + Compose ir patikrintos versijos. (Docker dar neįdiegtas.)
- [ ] Sukurti bei patikrinti persistent volumes.
- [x] Cloudflare DNS zona paruošta ir nameserver’iai pateikti registratoriui; propagacija dar vyksta.
- [ ] Sukurtas Cloudflare Tunnel.
- [ ] Veikia `supabase-staging.rinkissaupigiausia.online` per HTTPS Tunnel.
- [ ] Viešai nepasiekiami DB, pooler ir neapsaugotas Studio portai.
- [ ] VPS → R2 connectivity testas sėkmingas.
- [ ] Staging Supabase stack paleistas su prisegtomis versijomis; cron/refresh išjungti.

**Būsena:** VPS preflight, OS atnaujinimai, SSH hardening, UFW/Contabo firewall ir post-reboot patikra atlikti. Ubuntu 24.04.4, 11 GiB RAM, 193 GiB ext4 diskas (2 % naudojama), viešai klausosi tik SSH 22. Cloudflare domenas aktyvus; Docker, swap ir Tunnel dar neįdiegti.
**Pradėta:** 2026-07-16  
**Tikslas:** paruošti izoliuotą staging target, kuriame vėliau būtų galima atlikti pirmą restore rehearsal. Produkcinis Supabase šiame etape nekeičiamas.

## 1. Įėjimo sąlygos

| Įėjimas | Būsena | Pastaba |
|---|---|---|
| Contabo VPS Cloud VPS 6, ES | Patvirtinta | Plane numatyta 6 vCPU / 12 GB RAM / 200 GB SSD |
| Ubuntu LTS | Patvirtinta | Ubuntu 24.04 LTS |
| SSH key-only prieiga | Patvirtinta | `Accepted publickey for deploy` užfiksuota; password metodas dar išjungiamas |
| Ne-root administratoriaus paskyra | Reikia sukurti / patikrinti | `sudo` teisės, atskiras vardas, ne dokumento secretas |
| Cloudflare DNS zona | Reikia pasirinkti | Tunnel keliui domenas turi būti Cloudflare zonoje |
| Staging hostname | Siūloma | `supabase-staging.rinkissaupigiausia.online` |
| Studio hostname | Siūloma | `studio-staging.rinkissaupigiausia.online`, vėliau riboti prieigą |
| R2 secret failas | Paruoštas | VPS root-only failas jau sukurtas; reikšmės į repo nekeliamos |
| `age` identity | Escrow paruoštas | Į VPS kopijuojamas tik tada, kai reikės restore, su root-only ACL |

## 2. Architektūrinis sprendimas

Naudojamas atskiras Cloudflare Tunnel iš VPS į Cloudflare. Viešai publikuojami tik HTTPS hostname’ai; DB, pooler, Kong ir Studio administraciniai portai nėra atveriami tiesiogiai internete.

Numatomi staging vardai:

```text
supabase-staging.rinkissaupigiausia.online  → Kong / API gateway per Tunnel
studio-staging.rinkissaupigiausia.online    → Studio tik administracinei prieigai
```

Jei `rinkissaupigiausia.online` DNS lieka Hostinger zonoje, prieš Tunnel reikės perkelti nameserver’ius į Cloudflare arba pasirinkti Caddy/Nginx alternatyvą. Pastaroji alternatyva turi didesnį origin atakos paviršių, todėl pagal planą jos nesirenkame be atskiro patvirtinimo.

**Sprendimas:** DNS zoną kelti į Cloudflare ir naudoti Tunnel. Tai leis VPS nepublikuoti tiesiogiai, o staging hostname’ą valdyti vienoje vietoje.

### 2.1. DNS perkėlimo saugi seka

Nameserverių pakeitimas yra išorinis DNS pakeitimas, todėl pirmiausia reikia:

1. Hostinger zonoje eksportuoti / nufotografuoti visus dabartinius įrašus.
2. Cloudflare DNS zonoje sukurti visus esamus įrašus prieš keičiant nameserver’ius.
3. Ypač išsaugoti Resend įrašus: `resend._domainkey.auth`, `send.auth` TXT ir MX, taip pat domeno `www` / Pages įrašus.
4. Cloudflare DNS įrašams palikti `DNS only`, kol Tunnel maršrutai bus sukurti ir patikrinti.
5. Registratoriuje pakeisti nameserver’ius į Cloudflare pateiktus vardus.
6. Patikrinti, kad svetainė ir Resend domenas išlieka veikiantys; tik tada kurti Tunnel hostname’us.

Nameserverių reikšmės, Cloudflare API tokenai ir Tunnel tokenai į šį dokumentą neįrašomi.

### 2.2. 2026-07-16 DNS checkpoint

Pagal Cloudflare Dashboard ekrano patikrą:

| Patikra | Rezultatas |
|---|---|
| A įrašas `@` → `2.57.91.91` | Yra, `DNS only` |
| CNAME `www` | Yra, `DNS only` |
| MX `send.auth` → Resend bounce serveris | Yra, `DNS only`, priority 10 |
| TXT `send.auth` SPF | Yra, `DNS only` |
| TXT `resend._domainkey.auth` DKIM | Yra, `DNS only` |
| TXT `_dmarc` | Yra, `DNS only` |
| Cloudflare domeno būsena | `Waiting for your registrar to propagate your new nameservers` |

Pašto įrašai nustatyti saugiai: MX/SPF/DKIM/DMARC įrašai nėra proxinami. A ir `www` taip pat palikti `DNS only`, kol nepatikrintas tikras originas ir nesukurtas Tunnel. Nameserverių propagacija paprastai trunka 1–2 valandas, bet gali užtrukti iki 24 valandų.

## 3. 2026-07-16 VPS read-only preflight

| Patikra | Faktas | Vertinimas |
|---|---|---|
| OS | Ubuntu 24.04.4 LTS | Tinka planuojamam stack’ui |
| Kernel | Linux 6.8.0-124-generic, x86-64 | Užfiksuota prieš hardening |
| Diskas `/` | ext4, 193 GiB, naudota 2,2 GiB (2 %) | Didelė atsarga restore rehearsal’ui |
| Atmintis | 11 GiB prieinama iš 12 GB plano | Tinka pradinei staging aplinkai |
| Swap | Nėra | Prieš stack paleidimą rekomenduojamas kontroliuojamas swapfile |
| Klausantys portai | SSH 22 ir local systemd-resolved DNS | Nėra viešų DB / pooler / HTTP portų |
| Docker Engine | Nerastas | Reikia įdiegti prisegtą versiją |
| Docker Compose | Nerastas | Įdiegsime Compose plugin kartu su Docker |

UFW 2026-07-16 patikra: `Status: active`, incoming `deny`, outgoing `allow`, `22/tcp` ir `22/tcp (v6)` yra `LIMIT IN` iš `Anywhere`.

Contabo VPS firewall 2026-07-16 patikra: profilis `VPS firewall` aktyvus ir priskirtas 1 VPS; inbound taisyklės yra `ACCEPT TCP 22 / Any` bei `DROP Any / Any`. Nauja `deploy` PuTTY key-only sesija po firewall priskyrimo sėkminga.

### 3.1. 2026-07-16 post-reboot patikra

Po `sudo reboot` palaukta apie 2 minutes ir prisijungta nauja `deploy` + `.ppk` PuTTY sesija.

| Patikra | Rezultatas |
|---|---|
| Uptime | apie 2 min. po reboot |
| UFW | `active`, incoming `deny`, outgoing `allow` |
| SSH | `22/tcp` ir IPv6 `22/tcp` yra `LIMIT IN` |
| Klausantys portai | tik SSH 22 ir loopback systemd-resolved DNS |
| Cloudflare | domenas rodo `Your domain is now protected by Cloudflare` |

Tai patvirtina, kad firewall ir SSH hardening išlieka po host perkrovimo.

Papildomas faktas: `deploy` naudotojas sėkmingai prisijungė ir `sudo -v` grąžino sėkmę. `sudo -su` ir `sudo root` nėra reikalingos komandos: root administravimo shell’ui naudojama `sudo -i`, o įprastoms komandoms pakanka `sudo <komanda>`.

SSH hardening nustatymų ir end-to-end PuTTY patikra 2026-07-16 sėkminga: `permitrootlogin no`, `passwordauthentication no`, `kbdinteractiveauthentication no`, `pubkeyauthentication yes`. Neteisinga PuTTY sesija buvo atšaukta, o nauja sesija su tinkamai prikabintu `.ppk` raktu veikia.

Pirmas `99-aboutyou-hardening.conf` bandymas nekeičia efektyvios `passwordauthentication` reikšmės, nes Ubuntu / cloud-init konfigūracijoje ankstesnis failas nustatė `yes`. Problema išspręsta naudojant `00-aboutyou-hardening.conf` prioritetą.

`deploy` nauja PuTTY sesija ir `sudo` patikra sėkmingi. Žurnale užfiksuota ankstesnė `Accepted password` ir nauja `Accepted publickey`; todėl key-only kelias patvirtintas, bet password authentication dar turi būti išjungtas.

## 4. Vykdymo etapai

### 4.0. Kodėl reikalingas UFW ir Contabo firewall

VPS turi viešą IP ir šiuo metu SSH klausosi visame internete. **UFW** yra Ubuntu host’o ugniasienė: ji kontroliuoja, kurie įeinantys ryšiai leidžiami pačiame serveryje. **Contabo firewall** yra papildomas tinklo sluoksnis prieš VPS.

Tai nėra perteklinė apsauga šiam projektui, nes self-hosted Supabase turi duomenų bazę, Auth, Storage ir administracinį Studio. Minimalus modelis yra paprastas:

- pagal nutylėjimą atmesti visus įeinančius ryšius;
- leisti SSH 22 iš žinomų administratoriaus IP, VPN arba taikyti `ufw limit 22/tcp`, jei IP dinaminis;
- neatverti viešai Postgres `5432`, pooler `6543`, Docker, Studio ir vidinių Supabase portų;
- per Cloudflare Tunnel nereikia viešai atverti HTTP/HTTPS origin portų;
- leisti išeinantį srautą, kad veiktų atnaujinimai, Tunnel ir R2 backup.

Nauda: sumažėja automatinių portų skenavimų, brute-force bandymų ir netyčinio DB/Studio eksponavimo rizika. UFW ir Contabo firewall nesaugo nuo pažeistos aplikacijos ar pavogto SSH rakto, todėl jie yra gynybos sluoksnis, o ne vienintelė apsauga.

**Overkill būtų** sudėtingos VPN taisyklės ar IP allowlist’ai be poreikio. Jei administratoriui yra keli stabilūs IP, galima pridėti kelias `ufw allow from ...` taisykles. Jei IP keičiasi, praktiškas kompromisas yra `ufw limit 22/tcp` kartu su key-only SSH ir, vėliau, `fail2ban`. Prieš įjungiant būtina patikrinti key-only SSH ir turėti Contabo VNC/KVM/Rescue avarinį kelią.

#### 4.0.1. Pilna UFW instrukcija dinaminiam IP

Vykdyk komandas iš veikiančios `deploy` PuTTY sesijos, kurioje jau patikrintas `.ppk` raktas:

```bash
sudo ufw status verbose
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 22/tcp
sudo ufw --force enable
sudo ufw status numbered
```

Tikėtina UFW būsena:

```text
Status: active
Default: deny (incoming), allow (outgoing)
22/tcp                    LIMIT IN    Anywhere
22/tcp (v6)               LIMIT IN    Anywhere (v6)
```

`limit 22/tcp` leidžia SSH iš bet kurio dinaminio IP, bet riboja pakartotinius prisijungimo bandymus. Kadangi SSH password authentication išjungtas, autentifikacija lieka tik su public key.

Po įjungimo iš naujos PuTTY sesijos dar kartą patikrink:

```bash
sudo ufw status verbose
sudo -v
```

Jei reikia atšaukti tik UFW politiką avariniu atveju, dabartinėje sesijoje galima naudoti `sudo ufw disable`; tai neatstato password SSH ir neatidaro DB portų.

#### 4.0.2. Contabo firewall instrukcija

Sename Contabo skydelyje pasirink **Firewall (beta)**, sukurk atskirą firewall profilį ir priskirk jį šiam VPS. Minimalios inbound taisyklės:

| Protokolas | Portas | Šaltinis | Veiksmas |
|---|---:|---|---|
| TCP | 22 | Any / `0.0.0.0/0` ir `::/0` | Allow; UFW riboja bandymų dažnį |
| TCP | 80 | Any | Deny / nekurti taisyklės |
| TCP | 443 | Any | Deny / nekurti taisyklės, kol naudojamas Tunnel |
| TCP | 5432 | Any | Deny / nekurti taisyklės |
| TCP | 6543 | Any | Deny / nekurti taisyklės |
| TCP | 8000, 3000, 8080 | Any | Deny / nekurti taisyklės |

Outbound srautą palik leidžiamą, nes jo reikia OS atnaujinimams, Docker image’ams, Cloudflare Tunnel ir R2 backup. Jei Contabo firewall UI turi atskirą default politiką, inbound nustatyk `deny`, outbound `allow`.

Cloudflare Tunnel atveju į VPS nereikia atverti 80/443: `cloudflared` pats inicijuoja išeinantį ryšį į Cloudflare.

### 4.1. VPS ir OS hardening

- [ ] Užfiksuoti VPS IPv4, regioną, OS leidimą, disko dydį ir laiką UTC.
- [ ] Sukurti ne-root administratorių su `sudo`.
- [ ] Įkelti operatoriaus SSH public key.
- [ ] Išjungti root SSH login ir password authentication tik po patikrinimo nauja SSH sesija.
- [ ] Įjungti automatinius security updates pagal pasirinktą Ubuntu LTS politiką.
- [ ] Nustatyti UFW / Contabo firewall: deny by default; administracinis SSH tik iš patikimo šaltinio, jei įmanoma.
- [ ] Neatidaryti viešų `5432`, `6543`, DB, pooler ar vidinių Supabase portų.

### 4.2. Docker ir persistent storage

- [ ] Įdiegti Docker Engine ir Compose plugin iš oficialaus šaltinio.
- [ ] Užfiksuoti Docker / Compose versijas.
- [ ] Sukurti atskirą persistent mount’ą Supabase duomenims.
- [ ] Sukurti Docker network ir named volumes.
- [ ] Įjungti Docker log rotation; konteinerių logai negali neribotai auginti 200 GB disko.
- [ ] Prieš paleidimą patikrinti host disko, RAM ir inode rezervą.

### 4.3. Prisegtas self-hosted Supabase stack

- [ ] Pasirinkti ir užfiksuoti konkretų self-hosted Supabase release, nenaudoti `latest`.
- [ ] Pasirinkti Postgres versiją pagal source faktą: source yra PostgreSQL 17.6.
- [ ] Generuoti naujus staging secret’us; source JWT/API raktai į staging nekopijuojami.
- [ ] Įsitikinti, kad DB ir pooler portai bind’inami tik Docker network / localhost.
- [ ] Paleisti tik health-check paruoštą staging stack; cron ir read-model refresh lieka išjungti.

### 4.4. Cloudflare Tunnel ir hostname’ai

- [ ] Cloudflare zonoje sukurti atskirą Tunnel.
- [ ] VPS įdiegti `cloudflared` kaip system service, tokeną laikyti secret saugykloje.
- [ ] Tunnel route susieti su `supabase-staging.rinkissaupigiausia.online`.
- [ ] Studio route laikyti už papildomos Cloudflare Access / IP politikos; jo viešai anonimiškai neatverti.
- [ ] Patikrinti TLS ir išorės HTTP statusą tik per hostname.

### 4.5. Backup, monitoring ir connectivity

- [ ] VPS backup skriptas naudoja root-only R2 secret failą ir neįrašo tokeno į logus.
- [ ] Atlikti neprodukcinį R2 `list/head` connectivity testą.
- [ ] Patikrinti, kad R2 upload objektas yra kliento pusėje `age` užšifruotas.
- [ ] Įjungti disk usage, Docker health ir backup failure alertus.
- [ ] Sukonfigūruoti retention / log cleanup taip, kad diskas nestiprėtų nuo logų.

## 5. Stop vartai prieš 2 fazę

Į pirmą restore rehearsal galima eiti tik kai:

- [ ] VPS pasiekiamas tik SSH key-only administracine prieiga;
- [ ] viešai nepasiekiami `5432`, `6543`, DB, pooler ir neapsaugotas Studio;
- [ ] Docker volumes išlieka po konteinerių perkūrimo;
- [ ] konkretus Supabase release ir Postgres 17 suderinamumas užfiksuoti;
- [ ] staging hostname veikia per HTTPS Tunnel;
- [ ] R2 iš VPS pasiekimas patikrintas, o backup testinis objektas atkuriamas;
- [ ] cron / refresh writer’iai staging’e išjungti.

## 6. Kitas veiksmas

Kol Cloudflare laukia nameserverių propagacijos, VPS galima patikrinti read-only komandomis. Vykdyk VPS terminale kaip administratoriaus naudotojas ir įkelk tik išvestį be secretų:

```bash
hostnamectl
uname -a
df -hT /
free -h
ss -lntup
docker --version 2>/dev/null || true
docker compose version 2>/dev/null || true
```

Šios komandos nekeičia sistemos. Pagal jų rezultatą parinksiu tikslų hardening ir Docker diegimo etapą.

### 6.1. Kitas saugus vykdymas: SSH key-only paruošimas

VPS šiuo metu dar nehardening’intas. Pirmiausia pačiame VPS sukurk administratorių ir įrašyk savo **public** SSH key (private key niekur nekopijuojamas):

```bash
adduser deploy
usermod -aG sudo deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
nano /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
```

Iš savo kompiuterio atskiroje sesijoje patikrink:

```bash
ssh deploy@<VPS_IP>
sudo -v
```

Tik sėkmingai prisijungus su `deploy` galima VPS konsolėje taikyti SSH hardening:

```bash
cat >/etc/ssh/sshd_config.d/99-aboutyou-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
sshd -t && systemctl reload ssh
```

Po to įjungiamas firewall, leidžiant SSH tik iš patikimo administratoriaus IP (pakeisk placeholderį savo viešu IP):

```bash
apt update
apt install -y ufw unattended-upgrades ca-certificates curl gnupg
ufw default deny incoming
ufw default allow outgoing
ufw allow from <ADMIN_PUBLIC_IP> to any port 22 proto tcp
ufw --force enable
ufw status verbose
```

Jei administratoriaus IP nėra statinis, SSH taisyklę reikia spręsti per Contabo firewall / VPN; neatidaryk `22/tcp` visam internetui kaip ilgalaikio sprendimo.

### 4.1.1. Avarinis priėjimas prie VPS

Contabo senajame valdymo skydelyje tai gali nebūti pavadinta „Web Console“. Avarinio priėjimo reikia ieškoti per **VPS control** pasirinkus konkretų VPS ir ieškant **VNC / KVM / Console** funkcijos. Jei konkrečiam planui tokios funkcijos nėra, atsarginis kelias yra Contabo Rescue / OS reinstall meniu arba Support ticket. Prieš įjungiant UFW turi būti bent vienas veikiantis avarinis kelias.

### 6.2. OS atnaujinimas po `deploy` patikros

Kadangi Ubuntu praneša `System restart required`, pirmiausia iš `deploy` sesijos paleisk:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y ufw unattended-upgrades ca-certificates curl gnupg
```

Po atnaujinimo dar nedaryk `reboot`, kol nepatikrintas `deploy` prisijungimas su SSH raktu iš naujos terminalo sesijos. Tik tada taikomas SSH hardening ir planuojamas kontroliuojamas restartas.

Kad galėčiau pradėti realų 1 fazės vykdymą, reikia tik šių ne-slaptų faktų:

1. ar Contabo VPS jau sukurtas ir kokia jo OS (IP bei SSH raktas pokalbyje nesiunčiami);
2. ar `rinkissaupigiausia.online` DNS galima perkelti į Cloudflare;
3. kokį administratoriaus SSH public key naudoti (pateikiamas tik public key, private key nesiunčiamas).

Slaptažodžių, private key, Cloudflare Tunnel tokenų, R2 tokenų ar JWT į šį failą ir pokalbį kelti negalima.
