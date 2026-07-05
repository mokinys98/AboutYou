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
4. API paslaptis sukurkite per `wrangler secret put SUPABASE_URL` ir `wrangler secret put SUPABASE_SERVICE_ROLE_KEY` iš `apps/api`.
5. Paleiskite `npm install`, `npx playwright install chromium`, `npm run dev:api` ir kitame terminale `npm run dev:web`.
6. Admin puslapyje pridėkite 5–10 `https://www.aboutyou.lt/...` kategorijų ar brandų URL.
7. Vietinei sinchronizacijai paleiskite `npm run sync`.

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

Sinchronizavimo metu kas 5 s spausdinamas surinktų produktų ir srauto puslapių progresas. Vienai grupei taikomas 8 min. rinkimo timeout ir iki 4 bandymų kiekvienai nutrūkusiai srauto puslapio užklausai.

Pagrindinis prisijungimo būdas yra el. paštas ir slaptažodis. Magic link paliktas kaip alternatyva: Supabase Auth URL Configuration pridėkite vietinį `http://localhost:3000/auth/callback` ir produkcinį Cloudflare Pages callback URL. Viešą naudotojų registraciją išjunkite. Produkciniam magic-link laiškų siuntimui sukonfigūruokite nuosavą SMTP tiekėją, nes numatytasis Supabase siuntimas yra skirtas tik bandymams ir turi griežtus limitus.

Jei katalogo srautas nepateikia spalvos arba kategorijos, sinchronizatorius jas
papildo iš produkto puslapio JSON-LD. Kategorijos breadcrumb išplečiamas iki
kairiojo meniu tėvinės struktūros. Vienu paleidimu pagal nutylėjimą praturtinama
iki 100 produktų, siunčiant po vieną užklausą ne dažniau kaip kas 750 ms. Ribas
galima keisti per `SYNC_COLOR_ENRICHMENT_LIMIT`,
`SYNC_COLOR_ENRICHMENT_CONCURRENCY` ir `SYNC_COLOR_ENRICHMENT_DELAY_MS`; jau
surinktos spalvos iš DB atkuriamos ir pakartotinai nebesiunčiamos. Didesnis tempas
gali sukelti laikiną ABOUT YOU Cloudflare 1015 blokavimą.

## Diegimas

- Cloudflare Pages build komanda: `npm run build --workspace @catalog/web`; output: `apps/web/dist`.
- Hono API: `npm run deploy --workspace @catalog/api`.
- GitHub Actions secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`.
- Web aplinkos kintamieji: `NUXT_PUBLIC_SUPABASE_URL`, `NUXT_PUBLIC_SUPABASE_ANON_KEY`, `NUXT_PUBLIC_API_BASE`.
- API `ALLOWED_ORIGIN` pakeiskite į produkcinį Pages domeną.

## Patikra

```bash
npm test
npm run typecheck
npm run build
```

Sinchronizatorius naudoja tik `aboutyou.lt` allowlist URL. Privatus parduotuvės srautas gali pasikeisti; tokiu atveju taisomas provider adapteris, o ankstesni DB duomenys lieka prieinami.
