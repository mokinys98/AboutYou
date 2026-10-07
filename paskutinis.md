
PuTTY patikros sėkmingos: Grafana duomenų bazė veikia, Prometheus sveikas, abu metrikų šaltiniai rodomi kaip up. Tai įrašiau [paslaugos apraše](C:/Users/Administrator/Documents/AboutYou/docs/PASLAUGOS_PRAPLETIMAS.md).
Dabar atverkite Grafana per SSH tunelį. PuTTY’e sukurkite antrą sesiją, kad dabartinis terminalas liktų atidarytas:
1. Užkraukite tą pačią išsaugotą PuTTY sesiją.
2. Eikite į Connection → SSH → Tunnels.
3. Įrašykite Source port 3001, Destination 127.0.0.1:3001, pasirinkite Local ir spauskite Add.
4. Grįžkite į Session, išsaugokite nustatymus, tada junkitės. Palikite šį PuTTY langą atidarytą.
5. Naršyklėje atverkite http://127.0.0.1:3001.
Prisijungimo vardas yra admin, slaptažodis — tas, kurį įvedėte kurdami /srv/monitoring/.env. Jei PuTTY praneš, kad vietinis prievadas 3001 užimtas, pasirinkite kitą Source port, pavyzdžiui, 13001; naršyklėje tada atverkite http://127.0.0.1:13001.