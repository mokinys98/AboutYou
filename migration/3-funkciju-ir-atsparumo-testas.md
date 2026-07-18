# 3B fazė — funkcijų ir atsparumo testas

## Progreso varnelės — atnaujinti pirmiausia

- [x] Staging katalogo sync apkrovos testas atliktas su `SYNC_MAX_PRODUCTS=500` ir 25 aktyviais targetais.
- [x] Automatinis `sync_runs` ir read-model refresh validavimo gate sėkmingas.
- [x] Po testo patikrinti host RAM, swap ir disko rezervai.
- [x] Užfiksuoti `sudo docker stats --no-stream` po apkrovos.
- [x] Užfiksuoti Postgres DB dydį ir `pg_stat_wal` po apkrovos.
- [x] Patikrinti metadata lenteles ir privačius `sync-debug` / `sync-raw` bucket’us prieš canary.
- [ ] Paleisti `Sync product metadata (staging)` canary su `max_products=50` ir patikrinti DB/Storage rezultatą.
- [ ] Patikrinti invite-only Auth: password login, magic link, invite, logout ir priverstinį re-login; savitarnos password recovery pagal patvirtintą politiką netestuojamas.
- [ ] Patikrinti, kad Worker validuoja staging Auth JWT per staging JWKS ir issuer.
- [ ] Patikrinti katalogą, filtrus, facets, cursor pagination, cache izoliaciją ir watchlist.
- [ ] Patikrinti product details, price history, raw/debug artefaktus, admin dashboard, users, brand tiers, sync target CRUD ir sync runs.
- [ ] Patikrinti Telegram `/start`, `/status`, profilio susiejimą ir testinį alert.
- [ ] Atlikti fizinių `sync-raw` ir `sync-debug` Storage objektų count, bytes ir atrinktų hash/ETag parity.
- [ ] Atlikti backup restore į disposable aplinką ir užfiksuoti RTO.
- [ ] Atlikti 250k reprezentatyvų testą arba formaliai patvirtinti mažesnę produkcinę ribą ir SLO.
- [ ] Patvirtinti dashboard p95, disko rezervą, refresh circuit-breaker ir monitoring/alertus.

**Būsena:** 3 fazė vykdoma. Katalogo rinktuvas, staging GitHub Actions ir read-model refresh gate atlaikė 500 produktų kiekvienam targetui testą. Host RAM ir disko rezervas pakankamas, tačiau metadata, Auth/JWKS, aplikacijos funkcijų, Storage parity, disposable restore ir 250k/SLO testai dar neatlikti. Production canary ir cutover dar negalimi.

## 2026-07-18 staging katalogo sync apkrovos testas

Paleistas GitHub Actions workflow `Sync catalog (staging)` su:

- `SYNC_MAX_PRODUCTS=500` kiekvienam aktyviam targetui;
- 25 aktyviais targetais;
- GitHub `staging` Environment;
- automatine `sync_runs` ir read-model refresh patikra.

### Rezultatas

- 25/25 targetų baigėsi `success`;
- apdorotas 10 521 produktas;
- katalogo sync truko 4 min. 26 sek.;
- sukurta refresh užklausa su `requested_version=37`;
- read-model refresh baigtas su `completed_version=37` ir `status=refreshed`;
- read-model refresh truko 24 953 ms;
- tuščių targetų, `partial` / `failed` run ir workflow klaidų nenustatyta.

Kai kurie targetai turėjo mažiau nei 500 realių produktų, todėl 10 521 produktų
rezultatas yra tikėtinas. Pavyzdžiui, `Lacoste` grąžino 3, `Hackett London` — 115,
o `Premium` kostiumų targetas — 213 produktų.

### VPS resursų checkpoint po testo

2026-07-18 operatorius užfiksavo:

| Metrika | Rezultatas | Vertinimas |
|---|---:|---|
| RAM | 11 GiB total, 2,6 GiB used, 9,1 GiB available | pakankamas rezervas |
| Swap | 4 GiB total, 512 KiB used | memory pressure nenustatytas |
| Root diskas | 193 GiB total, 20 GiB used, 174 GiB available | 11 % naudojama; virš 60 GiB GO ribos |
| Docker stats | 11 aktyvių konteinerių, bendra RAM apie 2,0 GiB | aiškaus memory pressure ar nevaldomo konteinerio nenustatyta |

Didžiausi momentiniai RAM vartotojai buvo `supabase-kong` (~690 MiB),
`supabase-db` (~287 MiB), `supabase-studio` (~268 MiB), Realtime (~214 MiB) ir
`supabase-pooler` (~206 MiB). Momentiniame CPU pjūvyje Kong naudojo 26,16 %, REST
5,19 %, o kiti konteineriai — mažiau nei 1,5 %. Tai yra vienkartinis matavimas, todėl
jis patvirtina pakankamą resursų rezervą, bet neatstoja ilgalaikio monitoringo ir p95
metrikų. DB konteinerio Block I/O rodė 1,18 GB skaitymo ir 11,9 GB rašymo.

### Postgres ir WAL checkpoint

2026-07-18 po apkrovos užfiksuota:

| Metrika | Rezultatas |
|---|---:|
| Postgres DB dydis | 797 MB |
| `pg_wal` katalogas | 816 MiB |
| WAL records nuo `stats_reset` | 16 238 683 |
| WAL full-page images | 292 070 |
| Sugeneruota WAL nuo `stats_reset` | 4014 MB |
| `wal_buffers_full` | 179 383 |
| `wal_write` / `wal_sync` | 259 278 / 79 063 |
| `stats_reset` | 2026-07-16 18:52:41 UTC |

`pg_stat_wal` reikšmės yra kaupiamos nuo `stats_reset`, todėl jos nėra vien tik 500
produktų/target testo kaina. 816 MiB aktyvus WAL šiuo metu telpa į turimą disko
rezervą, tačiau po metadata canary jį reikia pamatuoti dar kartą ir palyginti augimą.
Didelis `wal_buffers_full` skaičius žymi buvusius rašymo pikus per restore ir sync;
vien iš šio kaupiamo skaičiaus negalima spręsti apie nuolatinį našumo trūkumą.

`deploy` vartotojas sąmoningai neturi tiesioginės prieigos prie Docker socket, todėl
`docker stats --no-stream` be `sudo` grąžino `permission denied`. Tai nėra Docker
gedimas ir dėl to vartotojo nereikia pridėti prie privilegijuotos `docker` grupės.

## Auth migracijos sprendimas

Source Auth vartotojai nemigruojami. Pirmas pilnas SQL data importas sustojo dėl
source ir self-hosted Auth schemų neatitikimo, todėl `auth.users` bei nuo jų
priklausomi duomenys buvo sąmoningai iškirpti iš katalogo-only restore. Target
naudoja invite-only modelį: vartotojai kuriami ir kviečiami naujai, o savitarnos
password recovery funkcija neįdiegiama. Šis sprendimas turi būti patikrintas per
invite, login, logout ir priverstinio re-login testus.

## Storage rollout prieš metadata canary

Šis darbų blokas reikalingas, nes staging VPS turi pradėti realiai saugoti
diagnostinius HTML ir raw produkto payload’us. Katalogo sync testas šios dalies
nepatikrino.

### Dabartinė būsena — 2026-07-18

- [x] Patikrinta, kad `product_sync_diagnostics`, `product_raw_sample_members` ir
  `product_sync_artifacts` lentelės staging DB jau egzistuoja.
- [x] Sukurtas private `sync-debug` bucket’as su `application/gzip` ir 5 MiB limitu.
- [x] Sukurtas private `sync-raw` bucket’as su `application/gzip` ir 5 MiB limitu.
- [ ] Paleistas `Sync product metadata (staging)` canary su `max_products=50`.
- [ ] Patikrinta, kad raw ir diagnostikos failai realiai įrašomi į Storage.
- [ ] Patikrinta, kad artifact įrašai turi `upload_status=ready`.
- [ ] Patikrintas bent vienas raw payload nuskaitymas per produkto debug API.

Bucket’ų patikra SQL Editor grąžino:

```text
sync-debug | public=false | file_size_limit=5242880
sync-raw   | public=false | file_size_limit=5242880
```

### Vykdymo seka

1. [x] Staging DB patvirtinti `product_sync_diagnostics`, `product_sync_artifacts`
   ir `product_raw_sample_members` objektai.
2. [x] Patvirtinti privatūs `sync-debug` ir `sync-raw` bucket’ai su
   `application/gzip` ir 5 MiB limitu.
3. [ ] Į `main` įkelti aktualų kodą ir paleisti `Sync product metadata (staging)` su
   `max_products=50`.
4. [ ] Po canary patikrinti, kad diagnostikos HTML ir raw gzip payload’ai pasiekė
   Storage, manifest įrašai turi `upload_status=ready`, o API debug vaizdas gali
   nuskaityti bent vieną raw payload’ą.
5. [ ] Patikrinti retention/cleanup rezultatus ir tik tada žymėti Storage vartus
   uždarytais.

### Stop/go vartai

- Jei migracija neįdiegta, bucket’ai nepasiekiami arba Storage nėra persistent —
  metadata canary nestartuoti.
- Jei `raw_archive_failed`, `upload_failed`, nėra `ready` artifact’ų arba private
  bucket’as pasiekiamas viešai — sustabdyti ir taisyti prieš kartojant.
- Storage parity laikyti užbaigta tik po faktinio objekto upload’o ir skaitymo
  patikros; vien `storage.objects` metaduomenų įrašų nepakanka.

## Kitas saugus veiksmas

1. GitHub Actions paleisti `Sync product metadata (staging)` su `max_products=50`.
2. Patikrinti metadata lenteles, `sync-raw` / `sync-debug` objektus, read-model refresh ir pakartoti DB/WAL dydžio matavimą.
3. Toliau vykdyti funkcinių testų matricą iš progreso bloko.

Mažas production canary nėra kitas žingsnis. Į production galima judėti tik uždarius
likusius 3 fazės funkcijų, Storage, restore, monitoring ir SLO vartus.
