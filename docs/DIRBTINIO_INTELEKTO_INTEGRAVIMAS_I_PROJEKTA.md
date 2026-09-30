# Dirbtinio intelekto integravimo į katalogą planas

> Būsena: kontrolinio rinkinio kodas parengtas; VPS migraciją ir faktinį API bandymą dar turi atlikti naudotojas.
> Atnaujinta: 2026-09-30.
> Pagrindinis tikslas: išnaudoti **OpenAI 1M grupės dienos pasiūlymą, jei organizacija jam tinkama**, ir paversti AI išgautus produkto požymius į filtruojamus katalogo metaduomenis. AI pokalbių pardavėjas nėra šio MVP pagrindas.

## 1. Sprendimas trumpai

1. Esamas ABOUT YOU katalogo ir metadata rinkimas lieka pirminiu produkto faktų šaltiniu. AI apdoroja tik aktyvius produktus, kuriems papildomi **vizualiniai** požymiai naudingi filtrams arba kurių šaltinio požymiai neaiškūs.
2. AI vieną kartą pagal produkto pagrindinę nuotrauką ir kelis jau žinomus metadata laukus grąžina trumpą, griežtos schemos šabloną. Programa, o ne modelis, susieja atsakymą su esamu `products.id`.
3. Normalizuoti laukai saugomi vienoje kompaktiškoje eilutėje produktui, su išoriniu raktu į `products`. Filtruojami laukai patenka į katalogo skaitymo modelį ir indeksus. Visų AI atsakymų, pokalbių, nuotraukų ar didelių JSON archyvų DB nekaupiame.
4. Atskirą mažų paketų AI procesą paleidžia **Cloudflare Cron Trigger** esamame API Worker, nepaleisdamas naujo GitHub Actions rinkimo darbo. Procesas turi savo dienos tokenų apskaitą, eilę ir stabdymo jungiklį.
5. Vartotojo spalvų profilį, individualų 0–100 balą ir „AI shopper“ atidedame. Kontroliniame rinkinyje jau kaupiame produkto spalvų šeimą, atspalvį, antrines spalvas, temperatūrą, šviesumą, sodrumą, kontrastą ir raštą, kad vėliau asistentas galėtų taikyti aiškias spalvų derinimo taisykles.

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

Pasiūlymo riba nėra programos konfigūracijos reikšmė. Pradiniame kontrolinio rinkinio kode vidinis limitas yra **200 000 tokenų UTC dienai**, nepriklausomai nuo 1M ar 250k pakopos. Tai palieka bent 50 000 tokenų atsargą net 250k pakopoje, tačiau kitas tos pačios organizacijos srautas šią atsargą gali sunaudoti. Ribą galima mažinti pagal realų naudojimą; kodas jos automatiškai nedidina ir didesnės nei 200 000 reikšmės nepriima.

Prieš **kiekvieną** OpenAI kvietimą viena DB transakcija rezervuoja konservatyvų blogiausio atvejo tokenų kiekį: įvertintas vaizdas ir promptas, nustatytas `max_output_tokens`, bei papildoma paklaida. Rezervacija turi unikalų užklausos ID ir UTC dieną. Vienu metu vykdomas pradžioje tik **vienas** kvietimas. Po atsakymo rezervacija pakeičiama faktiniu `usage.total_tokens`; jei atsakymas prarastas ar užklausa baigėsi neaiškiai, rezervacija neatlaisvinama be suderinimo. Jei kito kvietimo blogiausio atvejo dydis nebetelpa, procesas sustoja iki kitos UTC dienos. Ties dienos riba naujų kvietimų nepaleidžiame, kol ankstesni baigti ir apskaita suderinta.

Papildomi stabdikliai:

- `AI_ENRICHMENT_ENABLED=false`, `AI_INCENTIVE_VERIFIED=false`, `AI_CRON_ENABLED=false` pagal nutylėjimą; atskiras `AI_DAILY_TOKEN_CAP=200000`, vienas produktas per Cron paleidimą, `max_output_tokens=256` ir 20 s HTTP timeout.
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
  "saturation": "muted",
  "contrast": "medium",
  "visualPattern": "solid",
  "confidence": 0.91,
  "needsReview": false
}
```

Modelis **negrąžina** produkto ID, vartotojo ID, kainos, ilgo paaiškinimo ar neapribotų laisvo teksto laukų. Programa prideda `product_id` iš paimtos DB užduoties. `unknown` ir `needsReview` yra teisėtos baigtys, kai vaizdas netinka klasifikavimui. Schema validuojama programoje net ir naudojant struktūrizuotą išvestį. Spalvos iš nuotraukos yra apytikslės; esamų šaltinio `color_original`, `color_family`, `color_shade` ir `patterns` AI tyliai neperrašo. Nesutapimas žymimas peržiūrai.

## 5. DB modelis, dydis ir filtravimas

Dabartinė `product_ai_attributes` lentelė turi `product_id uuid primary key references products(id) on delete cascade`, atskirus normalizuotus požymių stulpelius, `source_image_fingerprint`, `metadata_fingerprint`, `schema_version`, `prompt_version`, `model` ir `analyzed_at`. `secondary_color_families` ribojamas iki dviejų reikšmių. Bandymų būsena ir trumpas klaidos kodas laikomi atskiroje `ai_control_requests` apskaitoje. Neįrašome OpenAI pilno atsakymo, prompto, base64 vaizdo ar dubliuotų šaltinio payload.

`ai_daily_usage` kaupia UTC dienos tokenų apskaitą, o `ai_control_requests` saugo rezervacijas ir jų baigtį. Neaiškių užklausų eilutės lieka iki rankinio suderinimo. Rezervavimo, užbaigimo ir suderinimo SQL funkcijos pasiekiamos tik serverio `service_role`; naujoms lentelėms įjungta RLS ir atimtos `anon` bei `authenticated` teisės. Istorijos valymo politika dar nenustatyta, todėl rezervacijų automatiškai netriname.

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

Dabartinio kontrolinio etapo kandidatai: tik į kontrolinį rinkinį ranka įtraukti aktyvūs produktai su pagrindine nuotrauka. Pagrindinės nuotraukos ar reikšmingų metaduomenų pokytis pakeičia fingerprint; tas pats rezultatas pakartotinai nesiunčiamas. Cron eilėje vėl atsiduria produktai pasikeitus nuotraukai arba schemos/prompto versijai. Vieną aktyvų kvietimą užtikrina DB unikalus indeksas ir tokenų rezervavimo transakcija. Neaiški klaida automatiškai nekartojama: ji sustabdo visą AI srautą iki rankinio Usage suderinimo.

AI kvietimas niekada nevyksta produkto kortelės HTTP užklausos metu. API tik skaito paruoštus požymius. Cloudflare Worker vykdymo trukmei taip pat taikomas atskiras paketo limitas ([Workers ribos](https://developers.cloudflare.com/workers/platform/limits/)).

## 7. Įgyvendinimo etapai

- [x] **Tinkamumas ir teisės.** Naudotojas patvirtino dalyvavimą programoje ir šio etapo teisingumą 2026-09-30. Faktinė 1M arba 250k pakopa ir pirmo kvietimo priskyrimas pasiūlymui dar tikrinami OpenAI Usage; iki tol `AI_ENRICHMENT_ENABLED=false`.
- [ ] **Kontrolinis rinkinys.** Rankiniu būdu sužymėti 50–100 įvairių prekių, išmatuoti `gpt-4.1-2025-04-14` tikslumą, `detail` lygį, įvesties ir išvesties tokenus, klaidų dalį. Vienu bandymu patikrinti, kad OpenAI Usage rodo pasiūlymo tier.
- [x] **Šablonas.** `packages/shared` pridėta versijuota požymių schema ir validacija; „unknown“ bei `needsReview` yra leistinos išvados. Tikras modelio tikslumas dar nematuotas.
- [x] **DB migracijos failas parengtas.** `supabase/migrations/20260930120000_ai_control_set.sql` sukuria kontrolinius rinkinius, žmogaus žymas, AI požymius, rezervacijas ir dienos apskaitą. `supabase/tests/ai_control_set_verification.sql` yra atskira tik skaitymo patikra. VPS migracija dar **nepaleista**: naudotojas pats įkelia visą migracijos failą į savo VPS Supabase SQL Editor ir paleidžia; tik jo pateikti sėkmingi vykdymo bei patikros rezultatai reiškia, kad migracija pritaikyta.
- [x] **Worker kodas parengtas.** Atskira valandinė Cron šaka ir rankinis admin kvietimas turi išjungtą pradinę būseną, vieno kvietimo lygiagretumą, atominę rezervaciją, 20 s timeout ir nepaleidžia GitHub workflow. Nei Cron, nei OpenAI kvietimas dar nepaleisti produkcijoje.
- [ ] **Viešo katalogo AI filtrų kelias.** Kontrolinis rinkinys naudoja esamą katalogo filtrų nuorodą prekėms atrinkti. AI požymiai kol kas rodomi admin kontrolėje; jų prijungimas prie viešo katalogo skaitymo modelio, facet skaičiavimo ir UI bus atskiras etapas po tikslumo patikros.
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

Naudotojas patvirtino tinkamumo ir teisių etapą. Tikroji organizacijos pakopa, Usage priskyrimas, Costs rezultatas ir VPS DB būsena iš šio repo nepatvirtinti. Nuotolinė VPS DB nebuvo pasiekta; jokia migracija ar AI užklausa nepaleista.

## Kontrolinio rinkinio naudojimas

1. Įkelkite **visą naujausio** `supabase/migrations/20260930120000_ai_control_set.sql` failo turinį į savo VPS Supabase SQL Editor ir paleiskite. Tada tame pačiame SQL Editor paleiskite atskirą tik skaitymo `supabase/tests/ai_control_set_verification.sql` užklausą. Laukiama: `relations_and_rls_ok=true`, `functions_ok=true`, iš pradžių visi trys skaitikliai `0`. PostgreSQL klaida reiškia nepavykusią migraciją: prieš kartojant reikia tik skaitymo diagnostikos ir negalima spėti, kad ankstesni teiginiai atšaukti.
2. Admin puslapyje atidarykite **AI kontrolė**. Įklijuokite savo katalogo filtro nuorodą, pvz. `?category=vyrams%3Edrabu%C5%BEiai%3Emar%C5%A1kin%C4%97liai&price_min=20&price_max=40`, sukurkite rinkinį, peržiūrėkite filtro prekes ir pasirinkite iki 100. Kaina nuorodoje rašoma eurais, o katalogo API gauna centus.
3. Žmogaus žymoje pažymėkite vizualines savybes ir pastabą. AI kortelė rodo modelio išvadą, tikrumą, `needsReview`, šaltinio spalvą ir žmogaus žymą. Nesutapimus galima peržiūrėti šalia nuotraukos. Jei nuotrauka pasikeičia, sena AI išvada kortelėje nelaikoma aktualia.
4. Vieno produkto mygtukas **Analizuoti su AI** veikia tik įjungus toliau aprašytus saugiklius. Valandinis Cron (`17 * * * *`, UTC) papildomai reikalauja `AI_CRON_ENABLED=true` ir apdoroja daugiausia vieną laukiančią kontrolinę prekę per paleidimą. Prieš didesnį paleidimą reikia žmogaus žymomis įvertinti 50–100 prekių tikslumą ir palyginti „low“ vaizdo detalumo rezultatą su poreikiu.

## Kaip valdyti išlaidas

**Vienintelis būdas garantuoti, kad ši integracija neišleis nė vieno euro, yra neleisti jai siųsti OpenAI užklausų:** palikti `AI_ENRICHMENT_ENABLED=false` arba nepridėti `OPENAI_API_KEY`. Dalyvavimas pasiūlyme savaime negarantuoja, kad konkreti užklausa bus nemokama; bandomasis kvietimas taip pat gali būti apmokestintas. Vidinis tokenų limitas ir OpenAI hard spend limitas sumažina riziką, bet negarantuoja absoliutaus 0 €: pasiūlymo krepšelis gali būti bendras su kitais organizacijos projektais, o [hard limit taikymas nėra momentinis](https://developers.openai.com/api/docs/guides/spend-limits).

Jei sutinkate su šia pirmojo bandymo rizika, naudokite atskirą šiai integracijai skirtą OpenAI projektą ir tik tam projektui išduotą raktą. Raktą pridėkite kaip Worker secret `OPENAI_API_KEY`, niekada neįrašykite į `wrangler.jsonc`, `.env` repozitorijoje ar naršyklės `NUXT_PUBLIC_*` reikšmes. OpenAI projekto nustatymuose įjunkite mažiausią leidžiamą **hard spend limit**, papildomai pranešimus, ir patikrinkite Usage/Costs bei 1M ar 250k pasiūlymo pakopą. Jei toje pačioje organizacijoje vyksta kitas tinkamas srautas, jo tokenai gali sumažinti likutį. Po vieno rankinio kvietimo patikrinkite, kad Usage rodo pasiūlymo tier, o Costs šios užklausos kainą `0`; jei ne, palikite automatiką išjungtą ir sustabdykite rankinius kvietimus.

Worker konfigūracijoje `AI_ENRICHMENT_ENABLED=false`, `AI_INCENTIVE_VERIFIED=false`, `AI_CRON_ENABLED=false` pagal nutylėjimą. Patikrinę Data Sharing lange suteiktą pakopą ir šio projekto įtraukimą, nustatykite `AI_INCENTIVE_VERIFIED=true` ir `AI_ENRICHMENT_ENABLED=true` vienam rankiniam kvietimui; `AI_CRON_ENABLED` palikite `false`, kol pirmo kvietimo Usage ir Costs nepatvirtins nemokamo priskyrimo. Tik tada galite įjungti valandinį procesą su `AI_CRON_ENABLED=true`. `AI_DAILY_TOKEN_CAP` pradžioje `200000` (250k pakopai su rezervu); kodas nepriima didesnio nei `200000` limito be peržiūros. Kiekvienam kvietimui atominiu būdu rezervuojama `10000` tokenų, naudojamas tik `gpt-4.1-2025-04-14`, viena nuotrauka su `detail=low`, daugiausia `256` išvesties tokenai, be įrankių ir automatinių pakartojimų. Neaiškus atsakymas užblokuoja kitą kvietimą, kol admin pagal OpenAI Usage įveda faktinį tokenų skaičių į suderinimo lauką. Nerašykite `0`, kol Usage nepatvirtino, kad užklausa nesunaudojo tokenų.
