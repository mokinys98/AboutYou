# 3 fazė — funkcijų ir atsparumo testas

## Staging katalogo sync apkrovos testas

Data: 2026-07-18

Paleistas GitHub Actions workflow `Sync catalog (staging)` su:

- `SYNC_MAX_PRODUCTS=500` kiekvienam aktyviam target’ui;
- 25 aktyviais target’ais;
- staging Supabase Environment;
- automatine `sync_runs` ir read-model refresh patikra.

### Rezultatas

- 25/25 target’ų baigėsi `success`.
- Apdorota 10 521 produktų.
- Katalogo sync truko 4 min. 26 sek.
- Sukurta refresh užklausa su `requested_version=37`.
- Read-model refresh baigtas su `completed_version=37` ir `status=refreshed`.
- Read-model refresh truko 24 953 ms.
- Tuščių target’ų, `partial` / `failed` run’ų ir workflow klaidų nenustatyta.

Kai kurie target’ai turėjo mažiau nei 500 realių produktų, todėl 10 521 produktų
rezultatas yra tikėtinas ir nelaikomas trūkumu. Pavyzdžiui, `Lacoste` grąžino 3,
`Hackett London` — 115, o `Premium` kostiumų target’as — 213 produktų.

### Išvada

Staging katalogo rinktuvas ir staging read-model refresh atlaikė 500 produktų
vienam target’ui testą. Katalogo sync logika ir DB validavimo gate’as veikė kaip
numatyta. Šis testas neįrodo VPS RAM ar disko rezervo, nes GitHub loguose nėra
VPS resursų metrikų; prieš production cutover dar reikia atskirai užfiksuoti
staging VPS `free -h`, `df -h` ir Postgres / Docker būseną.

Kitas saugus žingsnis — mažas production canary, o ne iškart pilnas katalogo
sync. Production canary turi būti paleistas tik po to, kai patikrintos staging
VPS resursų metrikos ir patvirtinta, kad production workflow naudoja teisingus
production secrets.
