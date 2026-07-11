# Privatus kainų katalogas

Nuxt 3, Hono, Supabase ir Playwright monorepo, periodiškai surenkantis pasirinktų ABOUT YOU LT grupių produktus ir kainų istoriją.

## Darbo vietos

- `apps/web` – privatus Nuxt katalogas ir administravimo UI.
- `apps/api` – autentifikuotas Hono API Cloudflare Workers.
- `apps/sync` – Playwright sinchronizavimo procesas.
- `packages/aboutyou-provider` – izoliuotas ABOUT YOU adapteris.
- `packages/shared` – Zod schemos ir bendri tipai.
- `supabase/migrations` – duomenų bazės schema, RPC ir RLS.

`aboutyou-price-sort.user.js` veikia kaip diagnostikos įrankis naršyklėje, o jo tiesioginio ABOUT YOU produktų srauto kolektorius taip pat naudojamas `apps/sync`. Jei tiesioginis srautas pasikeičia, provideris automatiškai bando DOM slinkimo fallback ir nepilno rezultato nežymi sėkmingu.

## Paleidimas

1. Sukurkite Supabase projektą ir paleiskite `supabase/migrations/202607050001_initial_catalog.sql`.
2. Supabase Dashboard sukurkite komandos naudotoją su slaptažodžiu, tada įrašykite jo `auth.users.id`, el. paštą ir rolę į `public.team_members`.
3. Nukopijuokite `.env.example` į `.env` ir užpildykite reikšmes.
4. API paslaptis sukurkite per `wrangler secret put SUPABASE_URL`, `wrangler secret put SUPABASE_SERVICE_ROLE_KEY` ir `wrangler secret put GITHUB_TOKEN` iš `apps/api`. GitHub fine-grained tokenui suteikite tik šio repo `Actions: write` teisę.
5. Paleiskite `npm install`, `npx playwright install chromium`, `npm run dev:api` ir kitame terminale `npm run dev:web`.
6. Admin puslapyje pridėkite 5–10 `https://www.aboutyou.lt/...` kategorijų ar brandų URL.
7. Vietinei sinchronizacijai paleiskite `npm run sync`.

### Kūrimo režimai

- Tikras Supabase ir tikras, jau įdiegtas API: `npm run dev:web:real`.
- Tikras Supabase, bet lokalūs API ir web: viename terminale paleiskite
  `npm run dev:api:real-db`, kitame – `npm run dev:web:real-db`.

Abu režimai Supabase adresą ir raktus ima iš šakninio `.env`. Antrasis režimas
tik perrašo web API adresą į `http://localhost:8787` ir lokalaus API leidžiamą
web origin į `http://localhost:3000`; paslaptys papildomuose config failuose
nedubliuojamos.

Jei duomenų bazė jau buvo sukurta anksčiau, papildomai paleiskite
`supabase/migrations/202607050002_product_attributes.sql`. Migracija iš karto
priskiria jau turimus produktus jų kategorijų sync grupėms ir atkuria prekės
rūšį iš pavadinimo. Dydžiai, medžiagos, raštai, savybės ir stiliai užsipildo per
kitą sinchronizavimą, kai šiuos laukus pateikia ABOUT YOU produktų srautas.

Po jos paleiskite `supabase/migrations/202607050003_catalog_filters_watchlist.sql`.
Ši migracija prideda detalius spalvų atspalvius, asmenines stebimas prekes,
Šaltinio LPL palyginimą ir kontekstinius katalogo facet'us.
Jei `003` migracija jau buvo pritaikyta, papildomai paleiskite
`supabase/migrations/202607050004_optimize_catalog_facets.sql`, kuri pašalina
pakartotinius katalogo view skenavimus facet'ų užklausoje. Po jos paleiskite
`supabase/migrations/202607050005_speed_up_contextual_facets.sql`, kuri filtrus
išpakuoja vieną kartą ir pašalina kartotinius matcher'io skaičiavimus.
Galiausiai paleiskite `202607050006_protect_catalog_from_empty_sync.sql` ir
`202607050007_reconcile_source_categories.sql`. Pastaroji leidžia tiksliam ABOUT
YOU kategorijų keliui pakeisti anksčiau heuristiškai priskirtas kategorijas.
Po jos paleiskite `202607050008_delete_sync_targets.sql`, kuri saugiai pašalina
sinchronizavimo grupes ir perskaičiuoja paveiktų produktų matomumą.
Pritaikę likusias `20260706...` migracijas, paleiskite
`202607070001_product_sync_diagnostics.sql`. Ji sukuria privačią metaduomenų
klaidų diagnostikos lentelę ir privatų `sync-debug` Storage bucket'ą.

Sinchronizavimo metu kas 5 s spausdinamas surinktų produktų ir srauto puslapių progresas. Vienai grupei taikomas 8 min. rinkimo timeout ir iki 4 bandymų kiekvienai nutrūkusiai srauto puslapio užklausai.

Pagrindinis prisijungimo būdas yra el. paštas ir slaptažodis. Magic link paliktas kaip alternatyva: Supabase Auth URL Configuration pridėkite vietinį `http://localhost:3000/auth/callback` ir produkcinį Cloudflare Pages callback URL. Viešą naudotojų registraciją išjunkite. Produkciniam magic-link laiškų siuntimui sukonfigūruokite nuosavą SMTP tiekėją, nes numatytasis Supabase siuntimas yra skirtas tik bandymams ir turi griežtus limitus.

### Komandos narių kvietimai

Administratoriaus „Vartotojai“ skiltis kvietimus siunčia per Supabase Auth Admin API. Lokaliai API aplinkoje nustatykite `WEB_APP_URL=http://localhost:3000`; produkcijoje Worker `WEB_APP_URL` turi sutapti su Cloudflare Pages adresu. Supabase Authentication → URL Configuration leidžiamų redirect adresų sąraše pridėkite:

- `http://localhost:3000/auth/invite`
- `https://aboutyou-private-catalog-web.pages.dev/auth/invite`

Supabase Authentication → Email Templates → Invite user šablonui naudokite temą `Kvietimas prisijungti prie Kainoraščio` ir turinį:

```html
<h2>Jūs pakviesti prisijungti</h2>
<p>Paspauskite nuorodą ir susikurkite savo slaptažodį.</p>
<p><a href="{{ .ConfirmationURL }}">Priimti kvietimą</a></p>
<p>Jeigu kvietimo nesitikėjote, šį laišką ignoruokite.</p>
```

Produkcijoje prijunkite Resend per Supabase Custom SMTP, patvirtinkite atskirą siuntimo subdomeną ir jo SPF, DKIM bei DMARC įrašus. Autentifikacijos laiškams išjunkite Resend link tracking. Viešas registravimasis turi likti išjungtas. Lokaliame Supabase kvietimų laiškus galima peržiūrėti Mailpit (`supabase status` parodo jo adresą).

Produkto detalės renkamos atskiru `sync:metadata` procesu tik iš struktūruoto
`ArticleDetailService/GetProductBulk` payload. Darbai rezervuojami DB lease, todėl
pakartotinis workflow neapdoroja jau užbaigto tos pačios parserio versijos produkto.
Statinės sekcijos atnaujinamos pasikeitus payload, o dydžių prieinamumas – ne dažniau
kaip kas 24 val. 403/429 sustabdo batch nepadidindamas produkto bandymų skaičiaus.
Ribas valdo `METADATA_SYNC_MAX_PRODUCTS`, `METADATA_SYNC_CLAIM_SIZE`,
`METADATA_SYNC_CONCURRENCY`, `METADATA_SYNC_DELAY_MS` ir
`METADATA_SYNC_MAX_RUNTIME_MINUTES`.

## Diegimas

- Cloudflare Pages build komanda: `npm run build --workspace @catalog/web`; output: `apps/web/dist`.
- Hono API: `npm run deploy --workspace @catalog/api`.
- Tas pats API Worker pagal UTC grafikus paleidžia GitHub Actions: katalogą `17 */6 * * *`, o produktų metaduomenis `47 * * * *`. Workflow failuose paliktas tik `workflow_dispatch`, todėl dvigubų paleidimų nėra.
- GitHub Actions secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`.
- Metadata workflow pagal nutylėjimą išsaugo iki 20 sanitizuotų ir gzip suspaustų
  nesėkmingų HTML pavyzdžių; ribą ir 14 dienų saugojimo terminą valdo
  `METADATA_DEBUG_HTML_LIMIT` ir `METADATA_DEBUG_RETENTION_DAYS`.
- Web aplinkos kintamieji: `NUXT_PUBLIC_SUPABASE_URL`, `NUXT_PUBLIC_SUPABASE_ANON_KEY`, `NUXT_PUBLIC_API_BASE`.
- API `ALLOWED_ORIGIN` pakeiskite į produkcinį Pages domeną.
- Worker `GITHUB_TOKEN` laikykite tik Cloudflare secret; `GITHUB_OWNER`, `GITHUB_REPO` ir `GITHUB_REF` nustatyti `apps/api/wrangler.jsonc`.
- Pirmiausia įkelkite workflow pakeitimus į `main`, tik tada diekite Worker, kad pereinant nuo GitHub `schedule` prie Cloudflare Cron nebūtų dvigubų paleidimų.

## Patikra

```bash
npm test
npm run typecheck
npm run build
```

Sinchronizatorius naudoja tik `aboutyou.lt` allowlist URL. Privatus parduotuvės srautas gali pasikeisti; tokiu atveju taisomas provider adapteris, o ankstesni DB duomenys lieka prieinami.
