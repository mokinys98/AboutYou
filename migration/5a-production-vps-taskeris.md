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
- [x] Production UI smoke užskaitytas kaip `PASS` ir užfiksuotas cutover dokumentacijoje.
- [ ] Palaukti, kol baigsis pilnas production katalogo sync; tada patikrinti jo suvestinę, VPS `sync_runs` įrašą ir read-model refresh (`43/43` ar naujesnį), ir tik po to uždaryti likusį katalogo checkpointą.

## Greitas rollback

- [ ] Sustabdyti rinkimo workflow.
- [ ] Pašalinti `environment: production-vps` iš abiejų production workflow.
- [ ] Grąžinus workflow į `main`, jie vėl naudos nepakeistus repository source secrets.

## Atidėta po paleidimo

- [x] `rinkissaupigiausia.online` užregistruotas Cloudflare Pages projekte; Worker `ALLOWED_ORIGIN` leidžia ir naują domeną, ir rollback `pages.dev` adresą (CORS `204` PASS).
- [ ] Cloudflare DNS pakeisti konfliktuojantį apex `A → 2.57.91.91` į proxied `CNAME @ → aboutyou-private-catalog-web.pages.dev` ir sulaukti Pages būsenos `active`.
- [ ] Po DNS aktyvavimo atnaujinti self-hosted Supabase Auth `SITE_URL` / redirect allowlist ir Worker `WEB_APP_URL`, tada pakartoti login bei CORS smoke.
- [ ] Išorinis alert webhook.
- [ ] Sena `sync-raw` / `sync-debug` istorija.
- [ ] Telegram perjungimas.
- [ ] Pilnas invite / PKCE scenarijus.
- [ ] Pilnas metadata užpildymas.
