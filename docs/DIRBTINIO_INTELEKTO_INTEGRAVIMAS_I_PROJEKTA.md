# Dirbtinio intelekto integravimas į projektą

> Būsena: planas, dar neįgyvendinta  
> Parengta: 2026-07-21  
> Rekomenduojamas kelias: vienas serverio valdomas „OpenAI API“ projektas, produkto vaizdo analizė vieną kartą ir atskiras deterministinis balas kiekvienam vartotojui.

## Įgyvendinimo etapai ir smulkūs žingsniai

Atlikus punktą, `[ ]` pakeisti į `[x]`.

### 0 etapas – apsibrėžti vertinimo taisykles

- [ ] Nuspręsti, ką tiksliai reiškia „man tinka“: tik spalva ar ir raštas, kontrastas bei stilius.
- [ ] Aprašyti vartotojo spalvų profilį: sezonas, potonis, rekomenduojamos ir vengtinos spalvos, šviesumas, kontrastas.
- [ ] Pasirinkti pradinę balo formulę nuo 0 iki 100.
- [ ] Nustatyti balo kategorijas, pvz. `90–100 Puikiai tinka`, `70–89 Tinka`, `50–69 Neutralu`, `<50 Greičiausiai netinka`.
- [ ] Rankiniu būdu sužymėti 50–100 skirtingų produktų kontrolinį rinkinį.
- [ ] Nuspręsti, kokį modelio tikslumą laikysime pakankamu.

### 1 etapas – API ir išlaidų pagrindas

- [ ] Sukurti atskirą „OpenAI Platform“ projektą šiai aplikacijai.
- [ ] Nustatyti projekto mėnesio biudžetą ir perspėjimus apie sunaudojimą.
- [ ] Sukurti ribotų teisių API raktą.
- [ ] Lokaliai pridėti `OPENAI_API_KEY` tik į nekomituojamą `.env`.
- [ ] Produkcijoje raktą pridėti kaip „Cloudflare Worker“ secret, o ne paprastą `vars` reikšmę.
- [ ] Pridėti `OPENAI_VISION_MODEL`, pradžioje nustatant `gpt-5.4-nano`.
- [ ] Pridėti `OPENAI_VISION_FALLBACK_MODEL`, pradžioje nustatant `gpt-5.6-luna`.
- [ ] Numatyti bendrą ir vienam vartotojui taikomą užklausų limitą.

### 2 etapas – duomenų bazės schema

- [ ] Sukurti `user_color_profiles` lentelę.
- [ ] Sukurti `product_visual_analyses` lentelę bendrai, nuo vartotojo nepriklausomai produkto analizei.
- [ ] Sukurti `user_product_scores` lentelę vartotojo ir produkto balui.
- [ ] Pridėti analizės būsenas: `pending`, `processing`, `complete`, `retryable_error`, `permanent_error`.
- [ ] Pridėti `image_fingerprint`, modelio, prompto ir formulės versijas.
- [ ] Visoms viešoje schemoje esančioms lentelėms įjungti RLS.
- [ ] `user_color_profiles` ir `user_product_scores` politikose tikrinti `(select auth.uid()) = user_id`.
- [ ] Užtikrinti, kad analizės techninės lentelės nebūtų tiesiogiai prieinamos naršyklei.
- [ ] Paleisti duomenų bazės saugumo ir našumo patikras.

### 3 etapas – bendri tipai ir validacija

- [ ] `packages/shared` pridėti spalvų profilio Zod schemą.
- [ ] Pridėti AI analizės JSON schemą.
- [ ] Pridėti vartotojo produkto balo schemą.
- [ ] Aprašyti leistinas spalvų temperatūros, šviesumo, kontrasto ir rašto reikšmes.
- [ ] Pridėti schemų validacijos testus.

### 4 etapas – produkto vaizdo analizė

- [ ] Sukurti serverio funkciją, kuri gauna produkto pagrindinės nuotraukos URL ir metaduomenis.
- [ ] Kviesti „Responses API“ tik iš backend arba sinchronizavimo proceso.
- [ ] Reikalauti griežto struktūrizuoto JSON atsakymo.
- [ ] Pirminei analizei naudoti `gpt-5.4-nano` be papildomo reasoning.
- [ ] Jei pasitikėjimas žemas, prekė daugiaspalvė ar raštuota, pakartoti su `gpt-5.6-luna`.
- [ ] Patikrinti atsakymą Zod schema ir atmesti netaisyklingus rezultatus.
- [ ] Analizę išsaugoti pagal produkto ir nuotraukos fingerprint, kad ji nebūtų kartojama.
- [ ] Įdiegti timeout, iki 2 pakartojimų ir eksponentinį laukimą laikinoms klaidoms.
- [ ] Nesiųsti visų produkto nuotraukų, jei pakanka vienos pagrindinės.
- [ ] Pridėti struktūrizuotus logus be API rakto ir jautrių duomenų.

### 5 etapas – deterministinis tinkamumo balas

- [ ] Parašyti gryną funkciją `calculateColorCompatibility(profile, analysis)`.
- [ ] Pagrindinės spalvos atitikimui skirti pradinį 50 % svorį.
- [ ] Šiltam arba šaltam atspalviui skirti 20 % svorį.
- [ ] Šviesumui skirti 15 % svorį.
- [ ] Kontrastui skirti 10 % svorį.
- [ ] Raštui ir kelių spalvų deriniui skirti 5 % svorį.
- [ ] Riboti rezultatą į `0–100` intervalą.
- [ ] Grąžinti balą, kategoriją, trumpas priežastis ir pasitikėjimą.
- [ ] Formulę versijuoti, kad pakeitus taisykles būtų galima perskaičiuoti senus balus.
- [ ] Pridėti vienetinius testus ribiniams ir daugiaspalviams atvejams.

### 6 etapas – API endpointai ir foniniai darbai

- [ ] Pridėti `GET /v1/color-profile`.
- [ ] Pridėti `PUT /v1/color-profile`.
- [ ] Pridėti `GET /v1/products/:id/color-score`.
- [ ] Pridėti administratoriaus arba vidinį analizės paleidimo endpointą.
- [ ] Nevykdyti lėto AI kvietimo tiesiogiai katalogo kortelės užklausos metu.
- [ ] Sukurti foninę eilę ar periodinį batch procesą neanalizuotiems produktams.
- [ ] AI rezultatą skaičiuoti vieną kartą produktui, o vartotojo balą – pigiai iš esamų duomenų.
- [ ] Katalogo API pridėti balą tik tada, kai jis jau apskaičiuotas.
- [ ] Jei reikės rūšiavimo pagal balą, balus materializuoti duomenų bazėje.
- [ ] Atnaujinti katalogo cache invalidavimo taisykles.

### 7 etapas – vartotojo sąsaja

- [ ] Profilio puslapyje pridėti spalvų profilio redagavimo formą.
- [ ] Produkto kortelėje rodyti balą ir trumpą kategoriją.
- [ ] Produkto puslapyje rodyti išsamesnes balo priežastis.
- [ ] Aiškiai žymėti būseną „dar neįvertinta“.
- [ ] Pridėti filtrą, pvz. `Rodyti tik ≥ 70`.
- [ ] Pridėti rūšiavimą `Labiausiai man tinkantys` tik materializavus balus.
- [ ] Paaiškinti, kad vertinimas yra rekomendacija, o ne objektyvus spalvos matavimas.
- [ ] Patikrinti mobilų vaizdą, klaviatūros navigaciją ir ekrano skaitytuvų tekstus.

### 8 etapas – kokybės, kainos ir saugumo patikra

- [ ] Palyginti modelio požymius su 50–100 rankiniu būdu sužymėtų produktų.
- [ ] Išmatuoti balo sutapimą su žmogaus vertinimu.
- [ ] Patikrinti vienspalvius, daugiaspalvius, raštuotus ir prastai apšviestus produktus.
- [ ] Išmatuoti vieno produkto analizės kainą ir trukmę.
- [ ] Patikrinti, kad pakartotinė užklausa nenaudoja AI dar kartą.
- [ ] Patikrinti vartotojų duomenų izoliaciją ir RLS.
- [ ] Patikrinti rate limit, piktnaudžiavimo ir netikėto sąnaudų augimo scenarijus.
- [ ] Patikrinti, kad API raktas nepatenka į frontend bundle, logus ar Git istoriją.
- [ ] Įdiegti laipsniškai: administratorius → keli vartotojai → visi vartotojai.

### 9 etapas – produkcijos paleidimas

- [ ] Pritaikyti patikrintą duomenų bazės migraciją.
- [ ] Sukonfigūruoti produkcijos secrets ir išlaidų limitus.
- [ ] Paleisti ribotą pradinių produktų batch.
- [ ] Stebėti klaidas, kainą, trukmę ir žemo pasitikėjimo atvejus.
- [ ] Tik po stebėjimo įjungti balus visame kataloge.
- [ ] Dokumentuoti formulės ar modelio keitimo ir balų perskaičiavimo procedūrą.

---

## 1. Trumpas atsakymas apie API ir ChatGPT paskyrų limitus

Taip, rekomenduojamame variante būtų naudojamas „OpenAI API“. Jį kviestų projekto backend arba sinchronizavimo procesas, o ne vartotojo naršyklė.

Kiekvieno vartotojo ChatGPT Plus, Pro ar kitos ChatGPT prenumeratos limitų ši išorinė aplikacija panaudoti negali. „ChatGPT“ prenumerata ir „OpenAI API Platform“ yra atskiri produktai su atskira apskaita bei apmokėjimu. Vartotojo prisijungimas prie ChatGPT nesuteikia šiam katalogui teisės jo vardu naudoti API ir nurašyti ChatGPT žinučių limitą.

Oficialūs šaltiniai:

- [ChatGPT ir API atsiskaitymas valdomi atskirai](https://help.openai.com/en/articles/9039756-billing-settings-in-chatgpt-vs-platform)
- [ChatGPT prenumeratos negalima perkelti į API; API yra apmokestinamas atskirai](https://help.openai.com/en/articles/8156019-is-api-usage-included-in-chatgpt-subscriptions-even-if-i-have-a-paid-chatgpt-account)
- [ChatGPT Plus neapima API naudojimo](https://help.openai.com/en/articles/6950777-what)

Todėl praktiškas variantas yra vienas aplikacijos savininko valdomas API projektas su griežtu biudžetu, cache ir rate limitais.

## 2. Galimi atsiskaitymo ir autentifikavimo variantai

### A variantas – vienas projekto API raktas

Tai rekomenduojamas variantas.

Veikimas:

1. Projekto savininkas sukuria „OpenAI Platform“ projektą.
2. API raktas saugomas „Cloudflare Worker“ secrets.
3. Backend analizuoja produkto vaizdą.
4. Rezultatas išsaugomas duomenų bazėje ir pakartotinai naudojamas visiems vartotojams.
5. Kiekvienam vartotojui pritaikoma jo asmeninė balo formulė.

Privalumai:

- paprasčiausia vartotojo patirtis;
- vienoje vietoje kontroliuojamos sąnaudos;
- galima naudoti cache ir batch;
- nereikia rinkti svetimų API raktų;
- tinka dabartinei Hono, Cloudflare Workers ir Supabase architektūrai.

Trūkumai:

- API išlaidas apmoka projekto savininkas;
- būtini biudžeto, rate limit ir piktnaudžiavimo saugikliai.

Sudėtingumas: vidutinis. Kokybiškam MVP numatyti maždaug 3–5 darbo dienas, o pilnai versijai su batch, UI, testais ir stebėjimu – 1–2 savaites.

### B variantas – kiekvienas vartotojas pateikia savo API raktą

Tai naudotų vartotojo „OpenAI API Platform“ balansą, bet ne jo ChatGPT prenumeratos limitus.

Problemos:

- vartotojui reikia atskiros API paskyros ir mokėjimo metodo;
- slaptą raktą reikėtų saugiai perduoti ir šifruotai laikyti;
- reikėtų rakto atšaukimo, rotacijos, klaidų bei kvotų valdymo;
- prastesnė vartotojo patirtis;
- didesnė atsakomybė saugant kitų žmonių kredencialus.

„OpenAI“ rekomenduoja rakto niekada nedėti į naršyklę ir visus kvietimus nukreipti per backend: [API raktų saugumo rekomendacijos](https://help.openai.com/en/articles/5112595-best-practices-for-api-key-safety).

Sudėtingumas: aukštas. Prie pagrindinio varianto pridėtų apytiksliai 1–2 savaites saugiam raktų valdymui. Šiam privačiam katalogui nerekomenduojama.

### C variantas – atskira programa ChatGPT viduje

Teoriškai galima kurti ChatGPT programėlę arba GPT, kuris per MCP pasiektų katalogo backend. Tada vartotojas vertinimo prašytų ChatGPT aplinkoje, o ne katalogo svetainėje.

Tai nėra būdas nepastebimai naudoti vartotojo ChatGPT limitą dabartinio katalogo backend. Reikėtų kurti antrą vartotojo sąsają ChatGPT viduje, atskirą autentifikavimo srautą, MCP serverį ir duomenų prieigos teises. Katalogo kortelėse automatiškai rodomų balų šis variantas savaime nesuteiktų.

Sudėtingumas: aukštas, o rezultatas būtų kitas produktas. Galima svarstyti vėliau kaip papildomą sąsają, bet ne kaip pagrindinį integracijos kelią.

### D variantas – savarankiškai hostinamas vaizdo modelis

Galima nenaudoti komercinio API ir vaizdo modelį paleisti savo serveryje. Tačiau tada reikėtų:

- pakankamos CPU arba GPU infrastruktūros;
- modelio diegimo, atnaujinimo ir stebėjimo;
- atskiros vaizdų paruošimo bei išvesties validacijos;
- atlikti gerokai daugiau kokybės vertinimo;
- užtikrinti našumą batch metu.

Sudėtingumas: aukštas. Mažam privačiam katalogui pradžioje greičiausiai kainuotų daugiau laiko nei taupytų pinigų.

## 3. Rekomenduojamas modelių maršrutas

Pagrindinis modelis: `gpt-5.4-nano`.

Jis priima tekstą ir vaizdą, palaiko struktūrizuotą išvestį ir yra skirtas klasifikavimui, požymių ištraukimui bei reitingavimui. Tai atitinka užduotį, jeigu modelis nekuria galutinio subjektyvaus balo, o tik grąžina standartizuotus vaizdo požymius.

Fallback modelis: `gpt-5.6-luna`.

Jį naudoti tik tada, kai:

- prekė yra daugiaspalvė;
- raštas sudėtingas;
- nuotraukoje drabužis užima mažą plotą;
- `confidence` nesiekia nustatytos ribos;
- pirmo modelio išvestis neatitinka schemos.

Nereikia naudoti brangiausio modelio kiekvienai prekei. Oficialūs modelių aprašymai:

- [`gpt-5.4-nano`](https://developers.openai.com/api/docs/models/gpt-5.4-nano)
- [`gpt-5.6-luna`](https://developers.openai.com/api/docs/models/gpt-5.6-luna)

## 4. Kodėl AI neturėtų tiesiogiai sugalvoti galutinio balo

Jeigu modeliui būtų siunčiama nuotrauka ir prašoma tiesiog „duok score“, rezultatas galėtų svyruoti keičiantis promptui, modeliui ar net pakartojus tą pačią užklausą.

Patikimesnis procesas:

```text
Produkto nuotrauka ir žinoma ABOUT YOU spalva
                ↓
AI ištraukia standartizuotus spalvų požymius
                ↓
Rezultatas validuojamas ir išsaugomas vieną kartą
                ↓
Deterministinė formulė + vartotojo spalvų profilis
                ↓
Score 0–100, kategorija ir paaiškinimas
```

AI išvesties pavyzdys:

```json
{
  "dominantColors": [
    {
      "name": "navy",
      "hexApproximation": "#253451",
      "coveragePct": 82
    }
  ],
  "temperature": "cool",
  "lightness": "dark",
  "contrast": "medium",
  "pattern": "solid",
  "isMulticolor": false,
  "confidence": 0.91
}
```

Spalvos `hexApproximation` turi būti laikoma apytiksle. Produkto nuotraukos apšvietimas, kompresija ir baltos spalvos balansas reiškia, kad kalbos modelis nėra tikslus kolorimetras.

## 5. Pradinė balo formulė

Siūloma pirma versija:

| Požymis | Svoris |
|---|---:|
| Pagrindinių spalvų atitikimas vartotojo paletei | 50 % |
| Šiltas arba šaltas atspalvis | 20 % |
| Šviesumas | 15 % |
| Kontrastas | 10 % |
| Raštas ir kelių spalvų derinys | 5 % |

Formulė turi veikti programiniame kode, būti versijuojama ir turėti testus. Modelio `confidence` neturėtų automatiškai padidinti spalvos tinkamumo; jis turėtų nusakyti tik analizės patikimumą.

## 6. Siūlomas duomenų modelis

### `user_color_profiles`

Vienas aktyvus profilis vartotojui:

- `user_id`;
- `season`;
- `undertone`;
- `preferred_colors` JSON;
- `avoid_colors` JSON;
- `lightness_preference`;
- `contrast_level`;
- `profile_version`;
- `created_at`, `updated_at`.

Tai yra vartotojo duomenys, todėl RLS turi tikrinti konkretų `user_id`, ne vien tik `authenticated` rolę.

### `product_visual_analyses`

Bendra produkto analizė:

- `product_id`;
- `image_url`;
- `image_fingerprint`;
- `status`;
- `dominant_colors` JSON;
- `temperature`;
- `lightness`;
- `contrast`;
- `pattern`;
- `confidence`;
- `model`;
- `prompt_version`;
- `attempt_count`;
- `error_code`;
- `analyzed_at`.

Ji neturi `user_id`, nes tas pats produkto vaizdas visiems vartotojams yra vienodas.

### `user_product_scores`

Individualus, pigiai perskaičiuojamas rezultatas:

- `user_id`;
- `product_id`;
- `score`;
- `verdict`;
- `reasons` JSON;
- `formula_version`;
- `profile_version`;
- `analysis_version`;
- `calculated_at`.

Unikalus raktas: `(user_id, product_id)`.

## 7. Integracija su dabartiniu projektu

Projektas jau turi didžiąją dalį reikalingo pagrindo:

- produkto tipai ir `imageUrls`, `colorOriginal`, `colorFamily`, `colorShade` yra [`packages/shared/src/index.ts`](packages/shared/src/index.ts);
- katalogo užklausos ir produkto endpointai yra [`apps/api/src/index.ts`](apps/api/src/index.ts);
- produkto kortelė yra [`apps/web/components/ProductCard.vue`](apps/web/components/ProductCard.vue);
- vartotojo profilio puslapis yra [`apps/web/pages/profile.vue`](apps/web/pages/profile.vue);
- periodinis produktų ir metaduomenų rinkimas jau yra [`apps/sync`](apps/sync);
- duomenų bazės pakeitimai valdomi [`supabase/migrations`](supabase/migrations).

Logiškiausia AI analizę pridėti prie atskiro foninio proceso `apps/sync`, o ne tiesiai į produkto kortelės užklausą. Hono API turėtų grąžinti tik jau išsaugotą analizę ir vartotojo balą.

## 8. Cache ir sąnaudų kontrolė

Svarbiausia taupymo taisyklė: vienas produkto vaizdas analizuojamas vieną kartą, nepriklausomai nuo vartotojų skaičiaus.

Pakartotinė analizė reikalinga tik kai:

- pasikeitė pagrindinė nuotrauka arba jos fingerprint;
- pakeistas promptas;
- pakeistas AI modelis ir sąmoningai pradėtas pervertinimas;
- ankstesnė analizė baigėsi klaida;
- administratorius paleido rankinį pervertinimą.

Papildomi saugikliai:

- vienu metu apdorojamų produktų limitas;
- dienos arba mėnesio biudžetas;
- perspėjimai pasiekus, pvz., 70 %, 90 % ir 100 % biudžeto;
- batch vykdymo trukmės limitas;
- ne daugiau kaip 2 automatiniai retry;
- fallback modelis tik neaiškiems atvejams;
- trumpa struktūrizuota išvestis;
- produkto spalvos tekstą naudoti kaip papildomą signalą.

## 9. API rakto saugumas

`OPENAI_API_KEY`:

- negali būti `NUXT_PUBLIC_*` kintamasis;
- negali būti perduodamas naršyklei;
- negali būti įrašytas į repo ar testų fixture;
- negali būti spausdinamas loguose;
- produkcijoje turi būti „Cloudflare Worker“ secret;
- turi turėti ribotas teises, biudžeto perspėjimus ir būti periodiškai rotuojamas.

Visos „OpenAI“ užklausos turi eiti per serverį. Tai atitinka [oficialias API rakto saugumo rekomendacijas](https://help.openai.com/en/articles/5112595-best-practices-for-api-key-safety).

## 10. Privatumas

Jeigu siunčiamos tik viešos ABOUT YOU produktų nuotraukos ir bendri produkto metaduomenys, privatumo rizika yra palyginti maža.

Jeigu ateityje vartotojo spalvų profilis būtų nustatomas iš asmenukės:

- reikėtų aiškaus vartotojo sutikimo;
- reikėtų nuspręsti, ar originali nuotrauka apskritai saugoma;
- geriausia po analizės originalą ištrinti;
- reikėtų aprašyti saugojimo terminą ir ištrynimo procesą;
- nereikėtų iš nuotraukos nustatinėti nereikalingų jautrių savybių.

Pirmai versijai rekomenduojama leisti spalvų profilį įvesti rankiniu būdu ir nesiųsti vartotojo nuotraukos.

## 11. Kokybės vertinimas

Prieš analizuojant visą katalogą reikia parengti nedidelį reprezentatyvų rinkinį:

- šviesūs ir tamsūs vienspalviai drabužiai;
- šilti ir šalti atspalviai;
- balta, kreminė, pilka ir juoda;
- smulkūs bei stambūs raštai;
- daugiaspalvės prekės;
- nuotraukos su modeliu ir be modelio;
- nuotraukos su neutraliu ir spalvotu fonu.

Vertinti:

- ar teisinga dominuojanti spalva;
- ar teisinga temperatūra;
- ar teisingas šviesumas ir kontrastas;
- ar rezultatas stabilus pakartojus;
- ar `gpt-5.4-nano` pakanka;
- kiek atvejų iš tiesų reikia siųsti į fallback modelį;
- kiek kainuoja vienas produktas ir visas katalogas.

Modelį keisti tik remiantis šiais matavimais, o ne vien subjektyviu vienos nuotraukos įspūdžiu.

## 12. Priėmimo kriterijai MVP versijai

MVP laikomas baigtu, kai:

- vartotojas gali išsaugoti spalvų profilį;
- naujas produktas fone išanalizuojamas ne daugiau kaip vieną kartą tai pačiai nuotraukai;
- analizė atitinka griežtą schemą arba pažymima klaidos būsena;
- galutinis balas apskaičiuojamas deterministiškai;
- produkto kortelėje rodomas balas ir būsena;
- produkto puslapyje rodomos 2–3 trumpos priežastys;
- vieno vartotojo profilis ir balai nematomi kitam vartotojui;
- API raktas nepatenka į frontend ar Git;
- aiškiai išmatuota vieno produkto ir viso katalogo analizės kaina;
- egzistuoja testai balo formulei, validacijai ir pagrindiniams API endpointams.

## 13. Galutinė rekomendacija

Pirmai versijai naudoti vieną projekto valdomą „OpenAI API“ raktą. `gpt-5.4-nano` turi iš produkto nuotraukos ištraukti spalvinius požymius, o galutinį balą turi apskaičiuoti mūsų kodas. Tik neaiškius atvejus siųsti į `gpt-5.6-luna`.

Nebandyti naudoti kiekvieno vartotojo ChatGPT Plus ar Pro limitų, nes jie nėra skirti išorinės aplikacijos API užklausoms. Taip pat pirmoje versijoje nerinkti vartotojų API raktų ir nekurti atskiros ChatGPT programėlės – abu variantai smarkiai didina sudėtingumą, bet neduoda naudos pagrindiniam katalogo scenarijui.

## Dokumento uždarymas

- [ ] Baigta – galima ištrinti
