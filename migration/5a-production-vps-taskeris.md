# Production VPS cutover taskeris

## GitHub `production-vps` environment — prieš cutover

- [x] GitHub → **Settings** → **Environments** → **New environment**.
- [x] Environment pavadintas `production-vps`.
- [x] Neįjungti required reviewers ar deployment wait timer.
- [x] Pridėtas environment secret `SUPABASE_URL` su VPS Supabase HTTPS URL.
- [x] Pridėtas environment secret `SUPABASE_SERVICE_ROLE_KEY` su VPS service-role raktu.
- [x] Patikrinta, kad įrašyti abu secret pavadinimai:

```powershell
gh secret list --env production-vps
```

- [x] Esami repository secrets `SUPABASE_URL` ir `SUPABASE_SERVICE_ROLE_KEY` nepakeisti — jie lieka source rollback’ui.
- [x] Į `main` perkelti workflow, kuriuose nustatyta `environment: production-vps`.
- [x] Paleistas `Sync product metadata` su `max_products=50` — run `29664134768`.
- [x] Workflow sėkmingas: 50/50 complete, 0 retryable, 0 blocked schema, paprašytas refresh `43`.
- [x] Paleistas production `Sync catalog` — run `29664197881`.
- [x] Production `Sync catalog` run `29664197881` baigėsi `success` per `14 min 58 s` ir paprašė read-model refresh versijos `44`.
- [x] Production UI smoke užskaitytas kaip `PASS` ir užfiksuotas cutover dokumentacijoje.
- [x] VPS patikrintas naujausias `sync_runs`: `success`, `313` puslapių, `10000` produktų; read-model refresh `44/44 clean`.

## Greitas rollback

- [ ] Sustabdyti rinkimo workflow.
- [ ] Pašalinti `environment: production-vps` iš abiejų production workflow.
- [ ] Grąžinus workflow į `main`, jie vėl naudos nepakeistus repository source secrets.

## Atidėta po paleidimo

- [x] `rinkissaupigiausia.online` užregistruotas Cloudflare Pages projekte; Worker `ALLOWED_ORIGIN` leidžia ir naują domeną, ir rollback `pages.dev` adresą (CORS `204` PASS).
- [x] Cloudflare DNS konfliktuojantis apex `A → 2.57.91.91` pakeistas į proxied `CNAME @ → aboutyou-private-catalog-web.pages.dev`; domenas viešai grąžina `HTTP 200` ir build naudoja VPS Supabase bei production Worker.
- [x] Cloudflare Pages custom-domain būsena pasikeitė į `active`, validation taip pat `active`.
- [x] Worker `WEB_APP_URL` pakeistas į `https://rinkissaupigiausia.online`; deploy versija `46c50c94-0bc9-4b46-95e0-4c2f0f8df067`, `/health`, naujo domeno ir rollback domeno CORS patikros sėkmingos.
- [x] Self-hosted Supabase Auth `SITE_URL` pakeistas į `https://rinkissaupigiausia.online`, paliekant tikslius naujo domeno, rollback `pages.dev` ir localhost callback/invite URL allowlist’e; Auth `healthy`, settings ir JWKS grąžina `200`.
- [x] Login ir logout smoke pagrindiniame domene `https://rinkissaupigiausia.online` — `PASS`, patvirtino operatorius.
- [ ] Išorinis alert webhook. (Kam to reikia aiškinti)
- [ ] Sena `sync-raw` / `sync-debug` istorija. (Galime persikelti 20%, o kitus generuojam patys kai yra problemų)
- [x] Telegram perjungimas.
- [ ] Pilnas invite / PKCE scenarijus.
- [ ] Pilnas metadata užpildymas.
