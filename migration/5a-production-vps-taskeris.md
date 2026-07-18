# Production VPS cutover taskeris

## GitHub `production-vps` environment — prieš cutover

- [ ] GitHub → **Settings** → **Environments** → **New environment**.
- [ ] Environment pavadinti `production-vps`.
- [ ] Neįjungti required reviewers ar deployment wait timer.
- [ ] Pridėti environment secret `SUPABASE_URL` su VPS Supabase HTTPS URL.
- [ ] Pridėti environment secret `SUPABASE_SERVICE_ROLE_KEY` su VPS service-role raktu.
- [ ] Patikrinti, kad įrašyti abu secret pavadinimai:

```powershell
gh secret list --env production-vps
```

- [ ] Esamų repository secrets `SUPABASE_URL` ir `SUPABASE_SERVICE_ROLE_KEY` nekeisti — jie lieka source rollback’ui.
- [ ] Į `main` perkelti paruoštus workflow, kuriuose nustatyta `environment: production-vps`.
- [ ] Paleisti `Sync product metadata` su `max_products=50`.
- [ ] Patikrinti, kad workflow sėkmingas ir VPS read-model refresh yra švarus.
- [ ] Paleisti `Sync catalog` ir patikrinti naują VPS `sync_runs` įrašą.

## Greitas rollback

- [ ] Sustabdyti rinkimo workflow.
- [ ] Pašalinti `environment: production-vps` iš abiejų production workflow.
- [ ] Grąžinus workflow į `main`, jie vėl naudos nepakeistus repository source secrets.

## Atidėta po paleidimo

- [ ] Išorinis alert webhook.
- [ ] Sena `sync-raw` / `sync-debug` istorija.
- [ ] Telegram perjungimas.
- [ ] Pilnas invite / PKCE scenarijus.
- [ ] Pilnas metadata užpildymas.
