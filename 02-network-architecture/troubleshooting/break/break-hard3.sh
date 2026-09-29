#!/bin/bash
pid=$(docker inspect -f '{{.State.Pid}}' bucket-scanner)
cveth=$(bridge link show | sed -n 's/^[0-9]*: \([^@:]*\)[@:].*master br0.*/\1/p' | grep -vE '^(bond0|veth-ct-host)$' | head -1)
{
# --- 1. сервис в контейнере ---
case $((RANDOM % 6)) in
 0) pkill -f "http.server" ;;
 1) pkill -f "http.server"; ( cd /tmp && nsenter -t $pid -n -- python3 -m http.server 8080 --bind 127.0.0.1 &>/dev/null & ) ;;
 2) pkill -f "http.server"; ( cd /tmp && nsenter -t $pid -n -- python3 -m http.server 8081 &>/dev/null & ) ;;
 3) nsenter -t $pid -n ip link set eth down ;;
 4) nsenter -t $pid -n nft add table inet filter
    nsenter -t $pid -n nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
    nsenter -t $pid -n nft add rule inet filter input tcp dport 8080 counter drop ;;
 5) nsenter -t $pid -n nft add table inet filter
    nsenter -t $pid -n nft add chain inet filter output '{ type filter hook output priority 0; policy accept; }'
    nsenter -t $pid -n nft add rule inet filter output tcp sport 8080 counter drop ;;
esac

# --- 2. транзит через dev-router ---
case $((RANDOM % 5)) in
 0) ip netns exec dev-router nft delete table ip nat ;;
 1) ip netns exec dev-router sysctl -qw net.ipv4.ip_forward=0 ;;
 2) ip netns exec dev-router ip route del default ;;
 3) echo "nameserver 10.255.255.1" > /etc/netns/client1/resolv.conf ;;
 4) ip netns exec dev-router nft add table inet filter
    ip netns exec dev-router nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'
    ip netns exec dev-router nft add rule inet filter forward icmp type echo-request counter drop ;;
esac

# --- 3. канал: потери и MTU ---
case $((RANDOM % 3)) in
 0) tc qdisc add dev "$cveth" root netem loss 25% ;;
 1) ip link set "$cveth" mtu 1300 ;;
 2) ip link set veth-of mtu 1300 ;;
esac

# --- 4. бонд ---
case $((RANDOM % 4)) in
 0) ip netns exec dev-router ip link set veth1-peer nomaster ;;
 1) ip netns exec dev-router sh -c 'ip link set veth1-peer down; ip link set veth2-peer down' ;;
 2) ip link set bond0 nomaster ;;
 3) ip netns exec dev-router sh -c 'echo 0 > /sys/class/net/bond0/bonding/miimon' ;;
esac

# --- 5. policy-based routing ---
case $((RANDOM % 4)) in
 0) ip rule add from 10.0.0.0/24 lookup t_dev priority 20 ;;
 1) ip route replace default via 10.200.0.2 dev veth-host table t_office ;;
 2) ip route add 10.0.0.0/25 via 10.200.0.2 dev veth-host table t_office ;;
 3) ip route del 10.0.0.0/24 table t_dev ;;
esac

# --- 6. nftables хоста: NAT и forward ---
case $((RANDOM % 3)) in
 0) h=$(nft -a list chain ip nat postrouting | awk '/ip saddr 10.0.0.0\/24 masquerade/ {print $NF}' | head -1)
    [ -n "$h" ] && nft delete rule ip nat postrouting handle $h ;;
 1) h=$(nft -a list chain inet filter forward | awk '/iifname "br-office" oifname "enp0s3"/ {print $NF}' | head -1)
    [ -n "$h" ] && nft delete rule inet filter forward handle $h ;;
 2) h=$(nft -a list chain ip nat prerouting | awk '/dnat to 192.168.10.100/ {print $NF}' | head -1)
    [ -n "$h" ] && nft delete rule ip nat prerouting handle $h ;;
esac

# --- 7. таблица main ---
case $((RANDOM % 2)) in
 0) ip route replace 192.168.10.0/24 via 192.168.31.1 dev enp0s3 ;;
 1) ip route add 10.0.0.0/25 via 10.200.0.2 dev veth-host ;;
esac

# --- 8. маршрут контейнера / input хоста ---
case $((RANDOM % 3)) in
 0) nsenter -t $pid -n ip route del default ;;
 1) h=$(nft -a list chain inet filter input | awk '/iifname "veth-host" icmp type echo-request/ {print $NF}' | head -1)
    [ -n "$h" ] && nft delete rule inet filter input handle $h ;;
 2) h=$(nft -a list chain inet filter input | awk '/iifname "br-office" icmp type echo-request/ {print $NF}' | head -1)
    [ -n "$h" ] && nft delete rule inet filter input handle $h ;;
esac
} 2>/tmp/bh3.err
if [ -s /tmp/bh3.err ]; then echo "ОШИБКА:"; cat /tmp/bh3.err; else clear; echo "8 поломок применены"; fi
