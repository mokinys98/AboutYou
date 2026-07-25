# Katalogo sync ir VPS monitoriaus pataisymo planas

## Incidento išvada

2026-07-24 katalogo sync #94 metu 24 iš 25 grupių baigėsi sėkmingai. `Sportas` grupė pasiekė 266 puslapius, tačiau baigėsi su `products_count=0` ir `error=[object Object]`. Tai rodo, kad klaida įvyko saugojimo etape, o Supabase/PostgREST klaidos objektas buvo prarastas per `String(error)`.

Trys read-model laiškai buvo false positive: monitorius matė `requested_version > completed_version` su `pending`, tačiau per vieną kitą cron ciklą refresh sėkmingai baigėsi. Storage laiškas 2026-07-25 02:27 UTC sutapo su suplanuotu backup’o `docker pause supabase-storage`; backup baigėsi sėkmingai.

## Įgyvendinimo planas

### Sync diagnostika ir atsparumas

- Serializuoti `Error` ir Supabase/PostgREST objektus išsaugant `name`, `code`, `message`, `details`, `hint` ir `status`.
- Saugiai pašalinti `token`, `authorization`, `cookie` ir kitus slaptus laukus; ciklinius objektus sutrumpinti iki saugaus JSON.
- `sync_runs.error` tekstą riboti iki 2 000 simbolių.
- Kiekvienam `record_catalog_batch` loginti target, run ID, batch numerį/dydį, payload baitų dydį, trukmę, pirmą/paskutinį `externalId` ir normalizuotą klaidą.
- Transient klaidoms (`08xxx`, `40001`, `40P01`, `53300`, `57014`, `57P0x`, HTTP 429/502/503/504) taikyti iki trijų bandymų su 1 s ir 3 s backoff.
- Nežinomai klaidai atlikti vieną pakartojimą ir po nesėkmės nutraukti target su diagnostika.
- Deterministines `22xxx`/`23xxx` klaidas izoliuoti rekursyviai dalijant batch’ą pusiau; geras dalis išsaugoti, blogą singleton produktą atmesti, target pažymėti `partial`, o workflow palikti nesėkmingą.
- Pridėti pasirenkamą `SYNC_TARGET_LABEL` ir GitHub `workflow_dispatch` `target_label`; tuščia reikšmė išlaiko visų target’ų vykdymą.
- Diagnostikoje saugoti tik target, produktų ID, batch metrikas ir klaidą; neįrašyti service-role rakto ar pilno raw payload’o.

### VPS monitorius

- Pridėti `READ_MODEL_PENDING_MAX_AGE_SECONDS=900`.
- Šviežią `pending` būseną iki 15 min. laikyti informacine, o ne klaida.
- `last_status=failed`, netuščias `last_error`, pasenęs `pending` arba neparsita būsena turi būti `FAIL`.
- `supabase-storage` būseną vertinti kartu su `.State.Paused` ir aktyviu backup service: paused + aktyvus backup yra planuotas `PASS/INFO`, o paused be backup’o arba unhealthy ne paused yra `FAIL`.
- Installeris turi įrašyti naują nustatymą tik kuriant naują `monitor.env`, neperrašant esamo VPS konfigūracijos failo.

### Testai ir priėmimo kriterijai

- Vitest testai klaidų serializacijai, secret redaction, SQLSTATE/HTTP klasifikacijai, retry ir batch izoliavimui.
- Testas, kad `SYNC_TARGET_LABEL=Sportas` atrenka tik `Sportas`.
- Monitoriaus fixture testai šviežiam/pasenusiam `pending`, `failed`, backup pause ir tikram unhealthy.
- Paleisti `npm test`, sync workspace typecheck ir `bash -n` VPS skriptams.
- Po deploy patikrinti, kad nebėra `[object Object]`, normalus read-model refresh nesiunčia FAILED, o backup’o metu nėra Storage FAILED laiško.

## Rollout

1. Lokaliai paleisti testus ir typecheck.
2. Deployinti sync pakeitimus į GitHub Actions workflow.
3. VPS’e atnaujinti monitorių:

   ```bash
   sudo bash scripts/migration/install-vps-monitoring.sh
   ```

4. Įprastą automatinį sync palikti nepakeistą; tik diagnostikai galima atskirai paleisti `target_label=Sportas`.
5. Po pirmo naujo vykdymo į šį dokumentą įrašyti faktinius rezultatus, klaidos kodą, rejected produktus ir monitoriaus būseną.

VPS patikros komandos:

```bash
cd /srv/aboutyou
bash -n scripts/migration/vps-monitor.sh scripts/migration/install-vps-monitoring.sh scripts/migration/vps-monitor-logic.test.sh
bash scripts/migration/vps-monitor-logic.test.sh
```

## Vykdymo žurnalas

- [x] Incidento chronologija ir priežastys nustatytos.
- [x] Sync klaidų serializacija ir batch atsparumas įgyvendinti.
- [x] `SYNC_TARGET_LABEL` įgyvendintas.
- [x] VPS monitoriaus false positive pataisyti.
- [x] Vitest (12 failų, 98 testai) ir sync typecheck praėjo.
- [x] `git diff --check` praėjo (tik Git LF/CRLF perspėjimai).
- [ ] VPS’e paleisti `bash -n` (ši Windows aplinka neturi WSL distribucijos).
- [ ] VPS monitorius atnaujintas.
- [ ] Pirmo naujo sync rezultatas užfiksuotas.

## Priminimas po rollout

**Patikrinti po 1–2 dienų (2026-07-26–2026-07-27):**

- [ ] Ar per automatinius sync `Sportas` baigėsi `success`, o ne `[object Object]`.
- [ ] Jei yra klaida, užfiksuoti tikslų `code`, `message`, `details`, `hint` arba atmesto produkto `externalId`.
- [ ] Patikrinti, kad `aboutyou-vps-monitor.timer` aktyvus ir nėra nepagrįstų `FAILED` laiškų.
- [ ] Patikrinti, kad read-model `pending` per įprastą refresh ciklą nesukelia aliarmo.
- [ ] Po backup’o patikrinti, kad `supabase-storage paused` nesukėlė `Storage FAILED` laiško.
- [ ] Įrašyti faktinį rezultatą į šio dokumento vykdymo žurnalą.

Patikros komandos VPS’e:

```bash
sudo journalctl -u aboutyou-vps-monitor.service --since "2 days ago" --no-pager -o short-iso
sudo systemctl is-active aboutyou-vps-monitor.timer
sudo docker exec -i supabase-db psql -X -U postgres -d postgres -P pager=off -c "
select started_at at time zone 'Europe/Vilnius' as started_lt,
       status, pages_count, products_count, error
from public.sync_runs
where target_id = (select id from public.sync_targets where label = 'Sportas')
order by started_at desc limit 3;
"
```
