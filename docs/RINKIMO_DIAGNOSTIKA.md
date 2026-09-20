# Rinkimo patikra ir pataisų diegimas

2026-09-20 peržiūrėti katalogo ir metaduomenų rinkikliai, jų provideris, workflow ir DB funkcijos. Pradinė rinkimo diagnostika atlikta be VPS ir `.env`. Vėliau, savininkui atskirai leidus atlikti VPS migraciją, ji įvykdyta ir patikrinta; rezultatai žemiau. Produkcinio rinkiklio kodo diegimas ir rinkimo rezultatas dar nepatvirtinti.

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

### Papildoma GitHub darbo analizė: direct ir fallback

Analizuotas [darbas 35532542419 / job 106135579974](https://github.com/mokinys98/AboutYou/actions/runs/35532542419/job/106135579974), commit `349eab7`. Kol darbas vyksta, GitHub logs API jo žurnalo neduoda; konkreti priežastis patvirtinta savininko pateikta vykstančio darbo išvestimi.

`Calvin Klein Katalogas` 19:31:37 turėjo tik 1 užfiksuotą modulį, `Jack & Jones` — 0. Modulių sąrašas būdavo nukopijuojamas vieną kartą po 1,2 s. Vėlesni `GetProductStreamV2` atsakymai grįžo su HTTP 200, bet jų dekoderio rinkiklis jau neberado. Nepavykusio modulio paieškos Promise likdavo cache. Tada userscript persijungdavo į DOM: pirmos grupės 1040 prekių rinkimas užtruko 321,2 s. Analitikos CORS klaidos šiame žurnale neįrodo produktų API blokavimo — produktų API atsakymai buvo 200.

Pataisa nuolat perduoda naujai įkeltus `service.grpc` modulius į kolektorių, apima ir `lazy` modulius, tikrina `modulepreload` nuorodas ir ribotą laiką laukia naujų kandidatų. Nesėkminga paieška nebeužrakinama cache. Be to, pataisytas protobuf nežinomo lauko praleidimas: `pos += uint32()` naudodavo seną poziciją ir praleisdavo neteisingą baitų kiekį; nukirsti duomenys dabar sukelia klaidą, užuot leidę dekoderiui strigti.

**Fallback paliktas.** Pirmas katalogo bandymas naudoja tik direct. Antras vėl pradeda direct naujame naršyklės kontekste ir tik jam nepavykus gali naudoti DOM (`allowDomFallback: true`). 403/429 ar sustabdytas rinkimas DOM nepaleidžia. Diagnostikos komanda pagal nutylėjimą tikrina direct. `mode` rodo faktiškai naudotą metodą, o ne vien klaidos buvimą.

Gyvi šio kompiuterio bandymai, be DB saugojimo:

| Bandymas | Surinkta / šaltinio total | Laikas | Rezultatas |
|---|---:|---:|---|
| Tikslus darbo Calvin Klein URL, riba 1000, servisų moduliai dirbtinai vėluoja 3 s | 1000 / 1756 | 15,858 s | Direct, 31 puslapis, pradinis modulių sąrašas 0, fallback nenaudotas |
| Tas pats Calvin Klein URL, riba 5000 | 1729 / 1756 | 12,730 s | Direct iki srauto pabaigos, 54 puslapiai, `partial` dėl kiekio neatitikimo |
| Maudymosi drabužiai `20291`, riba 5000 | 1225 / 1257 | 8,363 s | Direct, 39 puslapiai, `partial` dėl kiekio neatitikimo |

Maudymosi kategorijos visų puslapių auditas užfiksavo 1245 srauto elementus: 1225 produktų korteles ir 20 kitų elementų (reklama, rekomendacijos, progreso blokai). Normalizuojant neatmesta nė viena prekė. Paskutinis atsakymas turėjo 0 elementų ir tuščią `nextState`. Vien šie duomenys nepaaiškina, kodėl `pagination.total` liko 1257; pilnos aprėpties laikyti patvirtinta negalima. Tokie atvejai dabar turi `stream_exhausted_before_total` įvykį ir aiškią klaidos priežastį, galiojančios prekės saugomos kaip `partial`. Dirbtinai bendras kiekis nemažinamas, nesurinktos prekės neišjungiamos.

Papildomos pataisos: 129 Vitest testai ir sync/provider TypeScript patikra praėjo. Šios modulių aptikimo pataisos dar tik vietiniame kode; pateiktas GitHub darbas vykdo ankstesnį commit. Šio etapo metu VPS nenaudotas ir papildomos DB migracijos nereikia.

### Paleidimas

Iš projekto šaknies:

```powershell
npm.cmd run diagnose:catalog -- "https://www.aboutyou.lt/c/vyrams/drabuziai-20290" 1000 120000
```

Argumentai: viešas LT kategorijos URL, prekių riba, tiesioginio rinkimo timeout milisekundėmis. Komanda nekrauna `.env`, nekuria Supabase kliento ir neįrašo duomenų į katalogą. Rezultatai lieka `test-results/catalog-diagnostics/<laikas>/`: `events.jsonl`, `summary.json`, `products.json`, `state-shapes.json`. Pastarajame saugomi tik laukų pavadinimai ir tipai, ne sesijų reikšmės. Šie failai neįtraukiami į Git. Produkciniai ir staging katalogo workflow dabar išsaugo diagnostikos logą ir po sėkmės (14 dienų).

Pasirenkamas ketvirtas argumentas — servisų JS užklausų vėlinimas milisekundėmis (0–10000), skirtas CI įkėlimo eiliškumui atkartoti:

```powershell
npm.cmd run diagnose:catalog -- "https://www.aboutyou.lt/c/vyrams-20202?brand=calvin-klein-underwear-1035%2Ccalvin-klein-389%2Ccalvin-klein-jeans-911" 1000 90000 3000
```

Svarbūs įvykiai: `initial_network_stream_decoded`, `stream_page_completed`, `collection_normalized`, `collection_timeout`, `catalog_collection_summary`, `catalog_batch_failed`. Pagal juos galima atskirti šaltinio pokytį, puslapiavimo strigimą, parserio atmetimus ir DB įrašymo klaidas.

Didelė bandoma kategorija turi apie 69 tūkst. prekių. 15 tūkst. riba nėra pilna jos aprėptis; tokį target reikia suskaidyti į mažesnes kategorijas, kad likusios prekės taip pat būtų reguliariai atnaujinamos. Vien ribos didinimas negarantuoja visų grupių apdorojimo per 45 min. workflow laiką.

## VPS migracija — vykdo savininkas

Kodo pataisos įsigalios įkėlus jas į workflow naudojamą šaką. Toliau pateiktos migracijos komandos paliktos kaip vykdymo aprašas. **2026-09-20 migracija jau sėkmingai atlikta VPS su atskiru savininko leidimu; pakartotinai vykdyti nereikia.** Savininkas pats įvedė `sudo` slaptažodį interaktyviame SSH lange.

Patvirtinta vykdymo išvestimi:

- Funkcijos savininkas prieš pakeitimą: `postgres`; savininkas ir privilegijos nekeisti.
- Migracija: `BEGIN`, `CREATE FUNCTION`, `UPDATE 0`, `COMMIT`.
- Patikros SQL patvirtino 24 val. pakartojimo politiką.
- `retryable_error` su `next_attempt_at = infinity`: **0 prieš ir 0 po migracijos**. Šiuo vykdymu anksčiau užstrigusių eilučių atkurta 0; ankstesnės jų būsenos pagal šią patikrą nustatyti negalima.
- Būsenų momentinė suvestinė: `complete` 50164, `pending` 1243, `retryable_error` 12004, `source_unavailable` 3496, `blocked_schema` 1. Suvestinė apima ir neaktyvias prekes. `retryable_error` turėjo baigtinius kito bandymo laikus; tai nėra įrodymas, kad tie bandymai jau įvyko.
- Vykdymas baigėsi `MIGRATION_COMPLETED_AND_VERIFIED`; įkeltas migracijos SQL ir pagalbiniai vykdymo bei patikros failai pašalinti tik po sėkmingos patikros.
- Vietinis vykdymo žurnalas: `test-results/vps-migration/verified.log` (neįtraukiamas į Git).

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

Nekeiskite savininko ir privilegijų klaidai apeiti. Išvestį pateikite peržiūrai. Nuotolinė migracija patvirtinta aukščiau; produkcinio rinkiklio kodo diegimas ir paskesnio rinkimo rezultatai dar nepatvirtinti.
