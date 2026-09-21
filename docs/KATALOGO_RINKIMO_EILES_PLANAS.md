# Katalogo rinkimo eilė

Įgyvendintas tęstinis katalogo rinkimas, skirtas dideliam katalogui, kuris netelpa į vieną GitHub Actions darbą. GitHub Actions lieka vykdytoju, o Supabase saugo ciklų, užduočių, lease ir patvirtintų paketų būseną.

## Veikimas

- Cloudflare Worker paleidžia `sync-catalog.yml` kas 15 minučių. Vienas GitHub darbas turi 20 min. avarinį limitą, o rinkiklis dirba iki 10 min.
- Eilė sukuria vieną aktyvų ciklą kiekvienam `sync_target`. Naujas ciklas tam pačiam target'ui sukuriamas ne dažniau nei kartą per 24 valandas.
- `catalog_target_parts` yra versijuotas skaidymo manifestas. Migracija saugiai sukuria po `root` dalį kiekvienam esamam target'ui. Vėlesnė migracija gali pridėti mažesnes kategorijų dalis, nekeisdama pirminio target'o ar jo produkto ryšių.
- Užduotys rezervuojamos atominiu `FOR UPDATE SKIP LOCKED` veiksmu. Lease galioja 3 min. ir darbuotojas jį pratęsia kas 30 s. Pasibaigęs lease grąžina užduotį į eilę; senas žetonas nebegali nieko įrašyti.
- Kiekvienas 200 produktų paketas gauna puslapio numerį ir stabilų produkto ID rinkinio hash. Pakartotas jau patvirtintas paketas grąžina `0` ir nekuria naujų kainos stebėjimų.
- `finish_sync_run(..., 'success', ...)` vykdomas tik užbaigus visas pirminio target'o manifesto dalis. Dalinės ar užblokuotos dalys nesikeičia dingusių prekių skaitiklių.
- 403/429 pristabdo visą šaltinį mažiausiai 60 min. Jei šaltinis grąžina `Retry-After`, naudojama ilgesnė reikšmė. Kitos laikinos klaidos kartojamos po 5, 15 ir 60 min.; nuo penkto bandymo dalis pažymima `blocked`.

Produkciniame eilės režime DOM slinkimo fallback išjungtas. Sugedęs tiesioginis srautas užduotį atideda su diagnostika, todėl lėtas fallback nebeišnaudoja viso darbo limito. Diagnostinė komanda ir atskiras GitHub workflow gali naudoti fallback tyrimui.

## Manifesto plėtimas

Esamos `root` dalys sąmoningai nebuvo spėjamos suskaidyti į 25 konkrečius URL. Prieš pridėdami smulkesnes dalis, patvirtinkite URL diagnostiniu workflow ir įtraukite juos vienoje naujoje migracijoje:

```sql
insert into public.catalog_target_parts (target_id, part_key, url, priority)
values
  ('<target-id>', 'clothing-shirts', 'https://www.aboutyou.lt/c/...', 100),
  ('<target-id>', 'clothing-trousers', 'https://www.aboutyou.lt/c/...', 110);

update public.catalog_target_parts
set enabled = false, updated_at = now()
where target_id = '<target-id>' and part_key = 'root';
```

Išlaikykite pirminio URL prekės ženklo ir kitus filtrus. Viena dalis turėtų turėti iki 5 000 produktų; 15 000 yra tik apsauginė riba. Dalys gali persidengti: produktai deduplikuojami pagal šaltinį ir išorinį produkto ID.

## Diagnostika ir patikra

GitHub Actions workflow **Diagnose catalog stream** neturi DB paslapčių. Paleiskite jį bendrai kategorijai, prekės ženklo filtrui ir Premium kategorijai. Artefakte `events.jsonl` turi būti `category_stream_module_matched`, `initial_network_stream_decoded`, `stream_page_completed` ir žinomas `expectedTotal`.

Tiesioginio srauto aptikimas dabar įtraukia ir `service.grpc-lazy…` asset modulius. Ankstesnis filtras juos atmesdavo, todėl GitHub rinkiklis pereidavo į lėtą slinkimą.

Vietinis SQL testas `supabase/tests/catalog_collection_queue_test.sql` tikrina lease perėmimą, seno lease atmetimą, idempotentišką puslapio įrašymą ir 60 000 sintetinių produktų ciklą. Jis skirtas tik tuščiai, izoliuotai testinei DB.

## VPS migracija

Pagal projekto `AGENTS.md`, migraciją VPS vykdo savininkas. Jei Pageant dar neturi privataus rakto, paleiskite jį ir slaptafrazę įveskite Pageant lange:

```powershell
Start-Process -FilePath "C:\Program Files\PuTTY\pageant.exe" `
  -ArgumentList '"C:\Users\Auris\Documents\contabo.ppk"'
```

Įkelkite tikslų migracijos failą:

```powershell
& "C:\Program Files\PuTTY\pscp.exe" `
  -agent `
  -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
  ".\supabase\migrations\20260921122000_add_catalog_collection_queue.sql" `
  deploy@169.58.26.120:/tmp/20260921122000_add_catalog_collection_queue.sql
```

Atidarykite interaktyvią sesiją:

```powershell
& "C:\Program Files\PuTTY\plink.exe" `
  -agent `
  -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
  deploy@169.58.26.120
```

VPS terminale, interaktyviai įvedę `sudo` slaptažodį, vykdykite:

```bash
sudo docker exec -i supabase-db psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d postgres \
  < /tmp/20260921122000_add_catalog_collection_queue.sql
```

Po sėkmingo vykdymo patikrinkite:

```sql
select status, count(*)
from public.catalog_collection_tasks
group by status order by status;

select t.label, c.status, c.started_at, c.finished_at, c.error
from public.catalog_sync_cycles c
join public.sync_targets t on t.id = c.target_id
order by c.started_at desc
limit 25;

select s.slug, paused_until, reason
from public.catalog_source_pauses p
join public.sources s on s.id = p.source_id;
```

Tik po sėkmingo vykdymo ir patikros pašalinkite laikiną failą:

```bash
rm -f /tmp/20260921122000_add_catalog_collection_queue.sql
exit
```
