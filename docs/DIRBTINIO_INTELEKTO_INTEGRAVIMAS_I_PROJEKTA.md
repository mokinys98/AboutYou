# Dirbtinio intelekto integravimo į katalogą planas

> Būsena: perrašytas planas, dar neįgyvendinta.
> Atnaujinta: 2026-09-29.
> Pagrindinis tikslas: išnaudoti **OpenAI 1M grupės dienos pasiūlymą, jei organizacija jam tinkama**, ir paversti AI išgautus produkto požymius į filtruojamus katalogo metaduomenis. AI pokalbių pardavėjas nėra šio MVP pagrindas.

## 1. Sprendimas trumpai

1. Esamas ABOUT YOU katalogo ir metadata rinkimas lieka pirminiu produkto faktų šaltiniu. AI apdoroja tik aktyvius produktus, kuriems papildomi **vizualiniai** požymiai naudingi filtrams arba kurių šaltinio požymiai neaiškūs.
2. AI vieną kartą pagal produkto pagrindinę nuotrauką ir kelis jau žinomus metadata laukus grąžina trumpą, griežtos schemos šabloną. Programa, o ne modelis, susieja atsakymą su esamu `products.id`.
3. Normalizuoti laukai saugomi vienoje kompaktiškoje eilutėje produktui, su išoriniu raktu į `products`. Filtruojami laukai patenka į katalogo skaitymo modelį ir indeksus. Visų AI atsakymų, pokalbių, nuotraukų ar didelių JSON archyvų DB nekaupiame.
4. Atskirą mažų paketų AI procesą paleidžia **Cloudflare Cron Trigger** esamame API Worker, nepaleisdamas naujo GitHub Actions rinkimo darbo. Procesas turi savo dienos tokenų apskaitą, eilę ir stabdymo jungiklį.
5. Vartotojo spalvų profilį, individualų 0–100 balą ir „AI shopper“ atidedame. Pirmiausia turi veikti naudingi visam katalogui bendri filtrai.

## 2. Ką iš tikrųjų duoda „complimentary daily tokens“

Pagal [OpenAI pasiūlymo sąlygas](https://help.openai.com/en/articles/10306912-sharing-feedback-evaluation-and-fine-tuning-data-and-api-inputs-and-outputs-with-openai), dienos tokenai **nėra automatiškai suteikiami visoms organizacijoms**. Organizacijos savininkas turi matyti tinkamumo pranešimą Data Sharing nustatymuose, įjungti API įvesties ir išvesties dalijimąsi pasirinktame projekte ir matyti įtraukimą į pasiūlymą. Reikia teigiamo API paskyros balanso. Dalijami įvesties ir išvesties duomenys gali būti naudojami OpenAI modeliams gerinti; prieš įjungiant reikia įvertinti teisę siųsti trečiosios šalies produkto nuotraukas ir nesiųsti vartotojų ar slaptų duomenų.

| Pasiūlymo grupė | Dienos riba tinkamai organizacijai | 1–2 naudojimo pakopos | Šiam planui |
|---|---:|---:|---|
| 1M grupė | iki 1 000 000 įvesties **ir išvesties kartu** | 250 000 | Naudojama, jei realiai suteikta 1M riba. Pradinis kandidatas `gpt-4.1-2025-04-14`. |
| 10M grupė | iki 10 000 000 kartu | 2 500 000 | Neįtraukta į šio plano biudžetą. Ankstesnio plano `gpt-5.4-nano`, `gpt-5.4-mini` ir `gpt-5.6-luna` priklauso čia. |

Riba bendra visiems atitinkamos grupės modeliams ir organizacijos srautui; atskiras API projektas savaime nesukuria atskiro 1M krepšelio. Skaitiklis atsinaujina **00:00 UTC**, ne po slenkančių 24 valandų. Jei viena užklausa peržengia ribą, **visa ta užklausa** apmokestinama įprastai. Pasiūlymas netaikomas įrankių naudojimui, evals, fine-tuning ir jų modeliams. Sąlygos gali keistis, todėl prieš paleidimą jas reikia dar kartą patikrinti.

Pradinis `gpt-4.1-2025-04-14` pasirinktas todėl, kad jis yra 1M grupėje, priima vaizdą ir palaiko struktūrizuotą išvestį ([modelio aprašas](https://developers.openai.com/api/docs/models/gpt-4.1)). Tai **kandidatas bandymui**, o ne pažadas, kad jis geriausiai atpažins kiekvieną spalvą. Kitą 1M grupės modelį galima rinktis tik palyginus tikslumą ir patikrinus jo įtraukimą į tuo metu galiojantį pasiūlymą. Automatinio perėjimo į 10M grupės modelį nebus.

### Privalomas patikrinimas prieš didesnį paleidimą

- Organizacijos savininkas patvirtina, kad Data Sharing lange matomas **1M**, o ne 250k pasiūlymas, ir kad dalijimasis įjungtas tik numatytam projektui.
- Vienas mažas bandomasis kvietimas parodo `data sharing incentive tier - input/output tokens` OpenAI Usage lange; abu tokenų tipai įtraukti, Costs lange nėra tos užklausos kainos. Jei to nematyti, automatinis procesas lieka išjungtas.
- Patikrinama, ar toje pačioje organizacijoje nėra kitų 1M grupės užklausų. Jei jų yra, mūsų DB apskaita negalės viena pati garantuoti nemokamo limito; reikia bendros organizacijos naudojimo apskaitos arba rezervuoti dar didesnę dalį ir sustabdyti automatiką, kai jos neįmanoma patikimai suderinti.

## 3. Dienos limitas ir saugikliai

Pasiūlymo riba nėra programos konfigūracijos reikšmė. Programoje nustatome **mažesnį vidinį limitą**: pradžioje daugiausia 800 000 tokenų UTC dienai, jei patvirtinta 1M teisė, arba 200 000, jei suteikta 250k. Likę 20 % yra rezervas matavimo netikslumui, vėluojančiai apskaitai ir kitam tos organizacijos srautui. Ribą galima mažinti pagal realų naudojimą; ji automatiškai nedidinama.

Prieš **kiekvieną** OpenAI kvietimą viena DB transakcija rezervuoja konservatyvų blogiausio atvejo tokenų kiekį: įvertintas vaizdas ir promptas, nustatytas `max_output_tokens`, bei papildoma paklaida. Rezervacija turi unikalų užklausos ID ir UTC dieną. Vienu metu vykdomas pradžioje tik **vienas** kvietimas. Po atsakymo rezervacija pakeičiama faktiniu `usage.total_tokens`; jei atsakymas prarastas ar užklausa baigėsi neaiškiai, rezervacija neatlaisvinama be suderinimo. Jei kito kvietimo blogiausio atvejo dydis nebetelpa, procesas sustoja iki kitos UTC dienos. Ties dienos riba naujų kvietimų nepaleidžiame, kol ankstesni baigti ir apskaita suderinta.

Papildomi stabdikliai:

- `AI_ENRICHMENT_ENABLED=false` pagal nutylėjimą; atskiras `AI_DAILY_TOKEN_CAP`, `AI_MAX_PRODUCTS_PER_RUN`, `AI_MAX_REQUEST_TOKENS` ir vykdymo laiko limitas.
- Viena pagrindinė nuotrauka, apribotas jos dydis ir pasirinktas vaizdo `detail` pagal kontrolinio rinkinio bandymą. Vaizdo tokenai taip pat skaičiuojami įvestyje ([OpenAI vaizdų tokenų taisyklės](https://developers.openai.com/api/docs/guides/images-vision)).
- Trumpas promptas, `strict` JSON schema, ribota išvestis; jokių įrankių kvietimų ar daugiapakopio „agentinio“ ciklo ([Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)).
- Laikinoms klaidoms daugiausia vienas pakartojimas, bet tik po naujos rezervacijos. 429 dėl finansinio ar pasiūlymo limito sustabdo darbą; jis nėra aklai kartojamas.
- Dienos Usage ir Costs suderinimas su OpenAI prietaisų skydeliu; įspėjimas ir stabdymas, jei aptikta apmokestinta užklausa.
- Atskiras projekto **mėnesinis hard spend limit** kaip paskutinė apsauga. Vien perspėjimai nestabdo srauto, o hard limit vykdomas ne momentiškai, todėl juo negalima pakeisti dienos rezervacijų ([OpenAI spend limits](https://developers.openai.com/api/docs/guides/spend-limits)).

Po 50–100 kontrolinių produktų matuojame vidutinį ir didžiausią `usage.total_tokens`. Dienos apdorojimo talpa apskaičiuojama iš realių duomenų: `vidinis_dienos_limitas / konservatyvus_tokenų_kiekis_vienam_produktui`. Visam katalogui nesiunčiame užklausų vien tam, kad būtų „išnaudotas“ krepšelis.

## 4. Minimalus AI atsakymo šablonas

Modelis grąžina tik leidžiamas, trumpas reikšmes. Pavyzdys iliustruoja laukus; galutinis enum sąrašas turi būti suderintas su `packages/shared`:

```json
{
  "dominantColorFamily": "blue",
  "dominantColorShade": "navy",
  "secondaryColorFamilies": [],
  "temperature": "cool",
  "lightness": "dark",
  "contrast": "medium",
  "visualPattern": "solid",
  "confidence": 0.91,
  "needsReview": false
}
```

Modelis **negrąžina** produkto ID, vartotojo ID, kainos, ilgo paaiškinimo ar neapribotų laisvo teksto laukų. Programa prideda `product_id` iš paimtos DB užduoties. `unknown` ir `needsReview` yra teisėtos baigtys, kai vaizdas netinka klasifikavimui. Schema validuojama programoje net ir naudojant struktūrizuotą išvestį. Spalvos iš nuotraukos yra apytikslės; esamų šaltinio `color_original`, `color_family`, `color_shade` ir `patterns` AI tyliai neperrašo. Nesutapimas žymimas peržiūrai.

## 5. DB modelis, dydis ir filtravimas

Siūloma viena nauja `product_ai_attributes` lentelė su `product_id uuid primary key references products(id) on delete cascade`. Joje: aukščiau išvardyti **atskiri tipizuoti stulpeliai**, `status`, `source_image_fingerprint`, `metadata_fingerprint`, `schema_version`, `prompt_version`, `model`, `analyzed_at`, `attempt_count`, `last_error_code`. `secondary_color_families` ribojamas, pavyzdžiui, iki dviejų reikšmių. Galima pridėti mažą papildomą JSONB tik retam nefiltruojamam požymiui, su dydžio riba. Neįrašome OpenAI pilno atsakymo, prompto, base64 vaizdo, dubliuotų šaltinio payload ar kiekvieno bandymo istorijos.

Atskirai reikia kompaktiškos `ai_daily_usage` ir trumpai saugomų užklausų rezervacijų apskaitos. Vėluojančių ar neaiškių užklausų negalima užmiršti išvalant istoriją. Prieš migraciją reikia pasirinkti atominių užduočių ir rezervacijų SQL funkcijų teises, RLS ir saugojimo terminą.

**Susiejimas su preke:** DB užsienio raktas ir unikalus `product_id` leidžia jungti AI požymius prie prekės. JSONB irgi gali būti indeksuojamas, tad problema nėra pats JSON formatas; filtrams patogiau aiškūs, validuojami stulpeliai ir pagal realias užklausas parinkti indeksai ([Supabase JSONB](https://supabase.com/docs/guides/database/json), [indeksai](https://supabase.com/docs/guides/database/postgres/indexes)).

**Katalogo kelias:** dabartinis API filtruoja `catalog_items_read_with_lpl`, o kontekstinius filtrų skaičius skaičiuoja `catalog_facets_cached` ir susijusios SQL funkcijos. Migracija turi pridėti pasirinktus AI laukus prie šio skaitymo kelio, jų filtrus prie `CatalogFiltersSchema`, API ir facet skaičiavimo. Vien tik įrašyti lentelę neužtenka. Pirmai versijai siūlomi du filtrai: vizualinis šviesumas ir vizualinis raštas; jų pavadinimai UI aiškiai atskiriami nuo šaltinio spalvos ir rašto. Po bandomųjų `EXPLAIN` užklausų indeksuoti naudojamus laukus, vengiant indeksuoti kiekvieną stulpelį „dėl visa ko“.

Dabartinis katalogo skaitymo modelis yra materializuotas ir atnaujinamas pagal prašomą refresh. AI paketai turi **vieną refresh prašymą po paketo**, o ne po kiekvienos prekės; kartu turi būti atnaujintas arba invaliduotas facet cache. Kol refresh nebaigtas, naujas požymis filtravime dar nematomas – tai numatytas vėlavimas. Reikia pamatuoti refresh trukmę ir DB apkrovą, nes dabartinis metadata sync jau naudoja tą patį mechanizmą.

DB dydį vertiname pagal `produktų_skaičius × vidutinis_kompaktiškos_eilutės_dydis + indeksai`, o po pirmo paketo pamatuojame tikrą `pg_total_relation_size`. Jei, tarkime, 70 000 eilučių užimtų po 1 KB, vien eilutės būtų apie 70 MB **prieš** indeksus ir PostgreSQL papildomą vietą. Tai orientyras, ne patvirtintas būsimos DB dydis. Neanalizuoti ir neaktyvūs produktai papildomos eilutės neturi.

Viešoje schemoje naujoms lentelėms taikoma RLS ir mažiausios būtinos teisės. Techninė analizės bei tokenų apskaitos lentelė neskaitoma tiesiogiai iš naršyklės. AI laukus klientams grąžina esamas API per valdomą katalogo kelią.

## 6. Darbo eiga be naujos GitHub Actions apkrovos

Dabar `apps/api/wrangler.jsonc` Cron Trigger paleidžia `apps/api/src/index.ts` planuoklį, kuris katalogo ir metadata rinkimui siunčia GitHub `workflow_dispatch`. AI šakoje tame pačiame Worker įdedamas atskiras mažas `scheduled()` apdorojimas, **be GitHub dispatch ir be Playwright**. Cloudflare Cron veikia UTC ([Cloudflare Cron Trigger dokumentacija](https://developers.cloudflare.com/workers/configuration/cron-triggers/)). Pradžioje pakanka vieno trumpo paleidimo per valandą ne tuo pačiu momentu kaip esami rinkimo paleidimai; tik matavimai gali pagrįsti dažninimą.

```text
ABOUT YOU katalogas → esamas metadata sync → products + image_urls
                                              ↓
Cloudflare Cron → aktyvių kandidatų paėmimas → tokenų rezervacija
                                              ↓
                         OpenAI 1M grupės modelis → validacija
                                              ↓
                      product_ai_attributes (product_id FK)
                                              ↓
                  paketinis katalogo refresh → indeksuojami filtrai
```

Kandidatai: aktyvūs produktai, turintys pagrindinę nuotrauką ir, jei galima, jau užbaigtą source metadata. Prioritetas naujoms arba kataloge matomoms prekėms. Fingerprint keičiasi pasikeitus pagrindiniam vaizdui ar reikšmingiems įvesties metadata; prompto arba schemos keitimas savaime neperanalizuoja viso katalogo – tam reikia aiškiai suplanuoto riboto backfill. Vienu metu vienas workeris paima vieną užduotį su laikina nuoma, kad dubliuotas Cron įvykis nesukeltų dviejų mokamų kvietimų. Laikina klaida grįžta į eilę su atidėjimu, nuolatinė klaida pažymima.

AI kvietimas niekada nevyksta produkto kortelės HTTP užklausos metu. API tik skaito paruoštus požymius. Cloudflare Worker vykdymo trukmei taip pat taikomas atskiras paketo limitas ([Workers ribos](https://developers.cloudflare.com/workers/platform/limits/)).

## 7. Įgyvendinimo etapai

- [ ] **Tinkamumas ir teisės.** Patvirtinti pasiūlymo prieinamumą, 1M arba 250k pakopą, teigiamą balansą, dalijimosi su OpenAI pasirinkimą ir teisę siųsti pasirinktus produkto vaizdus. Kol tai nepatvirtinta, `AI_ENRICHMENT_ENABLED=false`.
- [ ] **Kontrolinis rinkinys.** Rankiniu būdu sužymėti 50–100 įvairių prekių, išmatuoti `gpt-4.1-2025-04-14` tikslumą, `detail` lygį, įvesties ir išvesties tokenus, klaidų dalį. Vienu bandymu patikrinti, kad OpenAI Usage rodo pasiūlymo tier.
- [ ] **Šablonas.** `packages/shared` pridėti vieną versijuotą požymių schemą ir validaciją; išbandyti `unknown`, nesutapimą su šaltiniu ir netinkamą vaizdą.
- [ ] **DB migracija.** Parengti `product_ai_attributes`, užduočių rezervavimo ir dienos tokenų apskaitos SQL; FK, RLS, ribas ir indeksus. Parengti atskirą tik skaitymo verifikacijos SQL. Migracijos failą naudotojas pats įkelia į savo VPS Supabase SQL Editor ir paleidžia; tik jo pateikti sėkmingi vykdymo bei patikros rezultatai reiškia, kad migracija pritaikyta.
- [ ] **Worker.** Pridėti atskirą Cron šaką su išjungta pradine būsena, vieno kvietimo lygiagretumu, atomine rezervacija, timeout, aiškiu stabdymu ir be GitHub workflow.
- [ ] **Filtrų kelias.** Prijungti išsaugotus laukus prie katalogo skaitymo modelio, API, facet skaičiavimo ir UI. Refresh daryti paketais ir pamatuoti jo kainą DB.
- [ ] **Bandomasis paleidimas.** 50–100 produktų, tada tik ribotas dienos srautas. Palyginti žmogaus žymas, DB dydį, indeksų naudą, refresh trukmę, tokenų apskaitą ir OpenAI Costs. Tik po to didinti dienos paketą.
- [ ] **Priežiūra.** Stebėti neapdorotų aktyvių prekių skaičių, `needsReview`, klaidas, vidutinį ir blogiausią tokenų skaičių, vidinį dienos likutį bei realų apmokestinimą. Pasiūlymo ar tinkamumo pasikeitimas išjungia automatinį siuntimą.

## 8. MVP priėmimo kriterijai

- Kiekviena patvirtinta AI analizė susieta su tikru `products.id`, o pasikeitus nuotraukai sena išvada nelaikoma nauja.
- Esami šaltinio metaduomenys išlieka su savo kilme; AI požymiai filtruojami kataloge ir rodomi tik po sėkmingo read-model refresh.
- Vienam produkto fingerprint ir šablono versijai nėra dubliuotų AI kvietimų; klaidos ir pakartojimai įtraukiami į dienos limitą.
- Vidinis procesas sustoja prieš nustatytą UTC dienos ribą, net jei Cron paleidžiamas pakartotinai; neaiškus naudojimas blokuoja naujus kvietimus iki suderinimo.
- Bandomajame paleidime OpenAI Usage patvirtina pasiūlymo tier, Costs nerodo netikėto apmokestinimo, o DB ir filtrų užklausų našumas pamatuotas.
- AI darbai nepadidina katalogo ir metadata GitHub Actions eilių.

## Šio plano ribos

Tai architektūros ir darbų planas. Pasiūlymo tinkamumas, tikroji organizacijos pakopa, produkto nuotraukų naudojimo teisės ir VPS DB būsena iš šio repo nepatvirtinti. Nuotolinė VPS DB nebuvo pasiekta; jokia migracija ar AI užklausa nepaleista.
