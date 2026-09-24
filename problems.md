# Atviros problemos

## Katalogo rinkimas

1. Katalogo šaltinio `expectedTotal` dažnai neatitinka pagrindinio gauto grid srauto. Todėl užduotys teisingai lieka `retryable`, tačiau ciklas neužsibaigia. Pavyzdžiai iš `Sync catalog` run `35849146748`: `2233/2265`, `744/768`, `301/323`.

2. PostgreSQL `statement timeout` (`57014: canceling statement due to statement timeout`) masiškai nutraukia `record_catalog_collection_page` batch įrašus. `Sync catalog` run `35849146748` iš 23 paimtų užduočių 16 po šios DB klaidos buvo sėkmingai pažymėtos `retryable`; taigi stringa ne užduoties užbaigimo RPC, o iki 200 produktų įrašymo transakcija.
