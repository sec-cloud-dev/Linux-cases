#!/bin/bash
pid=$(docker inspect -f '{{.State.Pid}}' bucket-scanner 2>/dev/null)
ok(){ echo "OK   $1"; }
fail(){ echo "FAIL $1"; }

# --- функциональные проверки ---

ip netns exec client1 ping -c1 -W2 192.168.10.1   &>/dev/null && ok "шлюз 192.168.10.1"  || fail "шлюз 192.168.10.1"
ip netns exec client1 ping -c1 -W2 10.200.0.1     &>/dev/null && ok "хост 10.200.0.1"    || fail "хост 10.200.0.1"
ip netns exec client1 ping -c1 -W3 8.8.8.8        &>/dev/null && ok "интернет по IP"     || fail "интернет по IP"
ip netns exec client1 getent hosts google.com     &>/dev/null && ok "DNS резолв"         || fail "DNS резолв"
ip netns exec client1 ping -c1 -W2 192.168.10.100 &>/dev/null && ok "сканер ICMP"        || fail "сканер ICMP"

c=$(ip netns exec client1 curl -m5 -s -o /dev/null -w "%{http_code}" http://192.168.10.100:8080/ 2>/dev/null)
[ "$c" = "200" ] && ok "сканер :8080 малый запрос" || fail "сканер :8080 малый запрос (код $c)"

r=$(ip netns exec client1 curl -m20 -s -o /dev/null -w "%{http_code} %{size_download}" http://192.168.10.100:8080/big.bin 2>/dev/null)
[ "$r" = "200 52428800" ] && ok "сканер :8080 50МБ" || fail "сканер :8080 50МБ ($r)"

grep -q "MII Status: up" <(ip netns exec dev-router cat /proc/net/bonding/bond0 2>/dev/null) && ok "bond0 живой" || fail "bond0 живой"

n=$(ip netns exec dev-router grep -c "^Slave Interface" /proc/net/bonding/bond0)
[ "$n" = "2" ] && ok "bond0: оба слейва в бонде" || fail "bond0: слейвов $n из 2"

n=$(bridge link show | grep -c 'master br0')
[ "$n" = "3" ] && ok "br0: три порта" || fail "br0: портов $n из 3"

ip netns exec office1 ping -c1 -W2 10.0.0.5  &>/dev/null && ok "офис: шлюз 10.0.0.5" || fail "офис: шлюз 10.0.0.5"
ip netns exec office1 ping -c1 -W3 8.8.8.8   &>/dev/null && ok "офис: интернет"      || fail "офис: интернет"

c=$(ip netns exec office1 curl -m5 -s -o /dev/null -w "%{http_code}" http://10.0.0.5:8080/ 2>/dev/null)
[ "$c" = "200" ] && ok "офис: DNAT до сканера" || fail "офис: DNAT (код $c)"

n=$(ip rule | wc -l)
[ "$n" = "5" ] && ok "ip rule: 5 правил" || fail "ip rule: $n вместо 5"

n=$(ip route show table t_dev | wc -l)
[ "$n" = "3" ] && ok "t_dev: 3 маршрута" || fail "t_dev: $n вместо 3"

n=$(ip route show table t_office | wc -l)
[ "$n" = "3" ] && ok "t_office: 3 маршрута" || fail "t_office: $n вместо 3"

ip netns exec office1 ping -c1 -W2 10.200.0.1 &>/dev/null && ok "офис → хост 10.200.0.1" || fail "офис → хост 10.200.0.1"

# --- сравнение с эталоном ---

cmp_et(){
  if diff -q <(eval "$2") "/root/etalon/$1.txt" &>/dev/null; then
    ok "эталон: $3"
  else
    fail "эталон: $3 — расходится"
  fi
}
cmp_et rule       'ip rule'                           "ip rule"
cmp_et main       'ip route show table main'          "таблица main"
cmp_et t_dev      'ip route show table t_dev'         "таблица t_dev"
cmp_et t_office   'ip route show table t_office'      "таблица t_office"
cmp_et client1    'ip netns exec client1 ip route'    "маршруты client1"
cmp_et office1    'ip netns exec office1 ip route'    "маршруты office1"
cmp_et dev-router 'ip netns exec dev-router ip route' "маршруты dev-router"
cmp_et nft        'nft list ruleset | sed "s/counter packets [0-9]* bytes [0-9]*/counter/g"' "nftables"
cmp_et bond0      'ip netns exec dev-router sed -n "/Bonding Mode\|MII Polling\|Up Delay\|Down Delay/p" /proc/net/bonding/bond0' "конфиг bond0"
cmp_et scanner    'nsenter -t $(docker inspect -f "{{.State.Pid}}" bucket-scanner) -n ip route' "маршруты сканера"
