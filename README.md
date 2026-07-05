# Privatus kainų katalogas

Nuxt 3, Hono, Supabase ir Playwright monorepo, periodiškai surenkantis pasirinktų ABOUT YOU LT grupių produktus ir kainų istoriją.

## Darbo vietos

- `apps/web` – privatus Nuxt katalogas ir administravimo UI.
- `apps/api` – autentifikuotas Hono API Cloudflare Workers.
- `apps/sync` – Playwright sinchronizavimo procesas.
- `packages/aboutyou-provider` – izoliuotas ABOUT YOU adapteris.
- `packages/shared` – Zod schemos ir bendri tipai.
- `supabase/migrations` – duomenų bazės schema, RPC ir RLS.

Esamas `aboutyou-price-sort.user.js` paliktas kaip nepriklausomas diagnostikos įrankis.

## Paleidimas

1. Sukurkite Supabase projektą ir paleiskite `supabase/migrations/202607050001_initial_catalog.sql`.
2. Supabase Dashboard sukurkite komandos naudotoją, tada įrašykite jo `auth.users.id`, el. paštą ir rolę į `public.team_members`.
3. Nukopijuokite `.env.example` į `.env` ir užpildykite reikšmes.
4. API paslaptis sukurkite per `wrangler secret put SUPABASE_URL` ir `wrangler secret put SUPABASE_SERVICE_ROLE_KEY` iš `apps/api`.
5. Paleiskite `npm install`, `npx playwright install chromium`, `npm run dev:api` ir kitame terminale `npm run dev:web`.
6. Admin puslapyje pridėkite 5–10 `https://www.aboutyou.lt/...` kategorijų ar brandų URL.
7. Vietinei sinchronizacijai paleiskite `npm run sync`.

Magic-link autentifikacijai Supabase Auth URL Configuration pridėkite vietinį `http://localhost:3000/auth/callback` ir produkcinį Cloudflare Pages callback URL. Viešą naudotojų registraciją išjunkite.

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
