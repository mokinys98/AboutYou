# 6 fazė — stabilizavimas ir 24 val. stebėjimas

## Progreso varnelės — atnaujinti pirmiausia

- [ ] Užfiksuotas tikslus production cutover UTC laikas.
- [ ] T+15 min. automatinis preflight ir rankinis smoke sėkmingi.
- [ ] T+1 h. VPS monitorius, Worker logai ir sync/refresh būsena be kritinių klaidų.
- [ ] T+6 h. RAM, diskas, WAL, DB dydis ir API klaidos neperžengia ribų.
- [ ] Praėjo bent vienas automatinis katalogo ir metadata workflow.
- [ ] Praėjo bent vienas automatinis šifruotas R2 backup po cutover.
- [ ] T+24 h. atliktas galutinis smoke ir priimtas stabilizavimo GO.
- [ ] Source Supabase statusas pakeistas iš active rollback į sutartą retention būseną.

**Būsena:** nepradėta. Fazė prasideda tik po 5 fazės GO.

## Stebėjimo ribos

| Signalas | GO | Įspėjimas / STOP |
|---|---|---|
| Root diskas | `< 80 %` | `>= 80 %` tirti, `>= 90 %` STOP |
| Backup amžius | `< 36 h` | `>= 36 h` STOP |
| Docker konteineriai | visi healthy/running | bent vienas unhealthy/missing |
| Read model | requested = completed, error tuščias | versijos atsilieka arba yra error |
| Refresh cron | 2 aktyvūs, 0 failed per 30 min. | bet koks failed |
| Worker `/health` | HTTP 200 ir `ok=true` | ne 200 arba 5xx |
| Supabase JWKS | HTTP 200, yra keys | nepasiekiamas |
| API funkcinis smoke | login/catalog/write veikia | auth arba pagrindinis read/write neveikia |

## Checkpoint komandos

VPS:

```bash
sudo systemctl start aboutyou-vps-monitor.service
sudo journalctl -u aboutyou-vps-monitor.service -n 100 --no-pager
sudo docker stats --no-stream
free -h
df -h /
sudo docker exec supabase-db psql -P pager=off -U postgres -d postgres -c \
"SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;
 SELECT requested_version,completed_version,last_status,last_duration_ms,last_error
 FROM public.catalog_read_model_refresh_state;"
sudo docker exec supabase-db du -sh /var/lib/postgresql/data/pg_wal
```

Repo:

```powershell
$env:MIGRATION_PHASE="cutover"
npm.cmd run migration:preflight
Remove-Item Env:MIGRATION_PHASE
```

## Laiko seka

### T+15 min.

- kartoti preflight;
- login/logout ir katalogo smoke;
- patikrinti monitoriaus journal;
- patikrinti Worker observability klaidas.

### T+1 h.

- patikrinti pirmą scheduler’ių ciklą;
- patikrinti `sync_runs`, metadata checkpoint ir read-model refresh;
- patikrinti, kad nėra netikėtų source DB write operacijų.

### T+6 h.

- užfiksuoti VPS resursų lentelę;
- palyginti DB/WAL augimą su prieš-cutover checkpoint;
- patikrinti katalogo, filtrų, watchlist ir admin CRUD.

### T+24 h.

- patikrinti naujausią automatinį R2 backup ir jo service rezultatą;
- kartoti pilną preflight ir rankinį smoke;
- peržiūrėti Worker 5xx, VPS journal ir refresh cron istoriją;
- priimti GO arba pratęsti rollback-only langą.

## Incidentų taisyklė

Kritinis Auth, duomenų integralumo ar masinis API gedimas per sutartą rollback langą
vykdomas pagal [5 fazės rollback](5-produkcijos-perjungimas.md#rollback). Nekritiniai
gedimai dokumentuojami su UTC laiku, paveiktu endpoint’u, request ID ir sprendimu;
slapti raktai bei vartotojų duomenys į incidento dokumentą nekopijuojami.
