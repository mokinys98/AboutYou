# Rinkimo patikra ir pataisų diegimas

2026-09-20 peržiūrėti katalogo ir metaduomenų rinkikliai, jų provideris, workflow ir DB funkcijos. VPS nebuvo pasiektas, `.env` diagnostikai nenaudotas. Produkcijos klaidų dažnis ir paveiktų prekių skaičius dar nepatikrinti.

Patikra: vietiniai Vitest testai ir visų workspace tipų patikra; papildomai migracija vykdyta izoliuotame PostgreSQL 17 konteineryje be tinklo. `supabase/tests/metadata_retry_policy_test.sql` patvirtino senų užduočių atkūrimą, 24 val. pakartojimą, lease apsaugą ir schemos klaidų politiką. Šis testas kuria fiktyvias lenteles ir skirtas tik tuščiai vietinei testavimo DB, niekada VPS.

## Patvirtintos problemos ir pataisos

- Gyvame kategorijos HTML nebėra produktų `GetProductStreamV2` pradinės būsenos. Ją puslapis gauna asinchroniniu gRPC atsakymu. Kolektorius dabar perskaito to atsakymo kopiją per dabartinio parduotuvės modulio dekoderį; HTML kelias lieka palaikomas. Ankstesnis bandymas surinko tik 30 prekių per slinkimą, po pataisos — 1000 per 10,516 s, 31 srauto puslapis, 0 normalizavimo atmetimų. Tai šio kompiuterio vienas bandymas, ne VPS našumo garantija.
- Provideris tyliai mažino 15000 ribą iki 10000. Dabar palaikoma konfigūruojama riba iki 50000.
- Trys pasikartojantys puslapiai buvo laikomi srauto pabaiga. Dabar tai nepilnas rinkimas. Normalizavimo metu prarastos prekės taip pat įvertinamos prieš patvirtinant aprėptį.
- Nepilno rinkimo galiojančios prekės anksčiau visai nepasiekdavo saugojimo. Dabar jos išsaugomos, o paleidimas žymimas `partial`; dingimo skaitikliai neperskaičiuojami. `success` galimas tik gavus visą žinomą grupės kiekį. Riboti staging bandymai dėl to gali sąmoningai baigtis `partial` ir exit 1.
- HTTP užklausos laiko limitas dabar apima ir atsakymo turinio skaitymą. 403/429 nebekartojami keturis kartus ir stabdo kitų grupių rinkimą. Bendras tiesioginio rinkimo limitas valdomas `SYNC_COLLECTION_TIMEOUT_MS` (numatyta 480000 ms). Timeout atveju išsaugomas paskutinis gautas progreso snapshot, jei jis yra.
- Metaduomenų HTTP atsakymai atlaisvinami po kiekvienos prekės; darbuotojai pakartotinai patikrina ribojimą ir darbo terminą po laukimo. DB klaidose išlieka struktūruotas pranešimas.
- Po trečios laikinos metaduomenų klaidos DB nustatydavo `next_attempt_at = infinity`. Paruošta migracija keičia tai į 24 val. ir paskirsto senų užstrigusių `retryable_error` atkūrimą per 6 val. `blocked_schema` ir `source_unavailable` politika nekeičiama.

## Diagnostika be duomenų bazės

Iš projekto šaknies:

```powershell
npm.cmd run diagnose:catalog -- "https://www.aboutyou.lt/c/vyrams/drabuziai-20290" 1000 120000
```

Argumentai: viešas LT kategorijos URL, prekių riba, tiesioginio rinkimo timeout milisekundėmis. Komanda nekrauna `.env`, nekuria Supabase kliento ir neįrašo duomenų į katalogą. Rezultatai lieka `test-results/catalog-diagnostics/<laikas>/`: `events.jsonl`, `summary.json`, `products.json`, `state-shapes.json`. Pastarajame saugomi tik laukų pavadinimai ir tipai, ne sesijų reikšmės. Šie failai neįtraukiami į Git. Produkciniai ir staging katalogo workflow dabar išsaugo diagnostikos logą ir po sėkmės (14 dienų).

Svarbūs įvykiai: `initial_network_stream_decoded`, `stream_page_completed`, `collection_normalized`, `collection_timeout`, `catalog_collection_summary`, `catalog_batch_failed`. Pagal juos galima atskirti šaltinio pokytį, puslapiavimo strigimą, parserio atmetimus ir DB įrašymo klaidas.

Didelė bandoma kategorija turi apie 69 tūkst. prekių. 15 tūkst. riba nėra pilna jos aprėptis; tokį target reikia suskaidyti į mažesnes kategorijas, kad likusios prekės taip pat būtų reguliariai atnaujinamos. Vien ribos didinimas negarantuoja visų grupių apdorojimo per 45 min. workflow laiką.

## VPS migracija — vykdo savininkas

Kodo pataisos įsigalios įkėlus jas į workflow naudojamą šaką. Toliau esanti migracija papildomai reikalinga užstrigusioms metaduomenų užduotims atkurti. Codex jos VPS nevykdė.

Jei Pageant neturi rakto, paleiskite jį ir jo lange įveskite rakto slaptafrazę:

```powershell
Start-Process -FilePath "C:\Program Files\PuTTY\pageant.exe" `
  -ArgumentList '"C:\Users\Auris\Documents\contabo.ppk"'
```

Įkelkite dabartinį failą ir atidarykite interaktyvų SSH:

```powershell
& "C:\Program Files\PuTTY\pscp.exe" `
  -agent `
  -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
  ".\supabase\migrations\20260920190501_recover_transient_metadata_failures.sql" `
  deploy@169.58.26.120:/tmp/20260920190501_recover_transient_metadata_failures.sql

& "C:\Program Files\PuTTY\plink.exe" `
  -agent `
  -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
  deploy@169.58.26.120
```

VPS terminale (sudo slaptažodį įveskite interaktyviai):

```bash
sudo docker exec -i supabase-db psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d postgres \
  < /tmp/20260920190501_recover_transient_metadata_failures.sql

sudo docker exec -it supabase-db psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres
```

Atidarytame `psql` atlikite patikrą:

```sql
SELECT count(*) AS permanently_stuck_transient_errors
FROM public.product_detail_sync
WHERE status = 'retryable_error' AND next_attempt_at = 'infinity'::timestamptz;

SELECT pg_get_functiondef(
  'public.fail_product_detail(uuid,uuid,text,text,integer)'::regprocedure
);

SELECT status, count(*), min(next_attempt_at), max(next_attempt_at)
FROM public.product_detail_sync
GROUP BY status ORDER BY status;
```

Pirmas rezultatas turi būti 0, o funkcijos `retryable` šakoje trečiam ir vėlesniam bandymui turi būti 24 val. terminas. Išeikite iš psql su `\q`. Tik po sėkmingo vykdymo ir patikros:

```bash
rm -f /tmp/20260920190501_recover_transient_metadata_failures.sql
exit
```

Bet kuri PostgreSQL klaida reiškia sustojusią migraciją; nekartokite aklai. `must be owner of function` atveju pirmiausia tik skaitykite savininką:

```sql
SELECT p.oid::regprocedure, pg_get_userbyid(p.proowner) AS owner
FROM pg_proc p
WHERE p.oid = 'public.fail_product_detail(uuid,uuid,text,text,integer)'::regprocedure;
```

Nekeiskite savininko ir privilegijų klaidai apeiti. Išvestį pateikite peržiūrai. Nuotolinės migracijos ir produkcinio rinkimo rezultatai šiame dokumente dar nepatvirtinti.
