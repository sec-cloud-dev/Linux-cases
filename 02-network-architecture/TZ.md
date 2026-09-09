# Кейс блока 2 (продолжение блока 1): Полная сетевая архитектура

**I — `dev-router`:** IP-less `br0`+`bond0` на хосте; внутри namespace `dev-router` — парный `bond0` (active-backup, `miimon=100`) из `veth1-peer`+`veth2-peer`, IP `192.168.10.1/24`; `dnsmasq` внутри (DHCP `192.168.10.10–50`, gateway+DNS `192.168.10.1`); выход в интернет через `veth-dev` (`10.200.0.2/30`) ↔ `veth-host` (`10.200.0.1/30`) с MASQUERADE

**J — PBR:** три таблицы (`t_dev`, `t_office`, `t_wan`) в `/etc/iproute2/rt_tables`, `ip rule` по source для каждого сегмента (`dev-router`, офис `10.0.0.0/24`, WAN)

**K — Bonding/Bridging:** `bond-office` (`eth1`+`eth2`, active-backup, `10.0.0.5/24`); IP-less `br0` объединяет `bond0`+`veth-b1` (`client1`)+`veth-scanner-host` (контейнер `192.168.10.100/24`) — прямая L2-связность разработчиков с контейнером, минуя NAT

**L — nftables:** policy drop везде; SSH только из `10.0.0.0/24`; WireGuard (UDP `51820`) открыт всем; FORWARD к `bucket-scanner` только из `192.168.10.0/24`+`10.0.0.0/24`; DNAT `8080`→`192.168.10.100:8080` с ограничением source

**M — WireGuard:** split-tunnel для стажёра (`wg0` `10.8.0.1/24`, `AllowedIPs=10.8.0.0/24,/srv/project_net`); + сравнительный full-tunnel PBR (`t_intern`) для документации
