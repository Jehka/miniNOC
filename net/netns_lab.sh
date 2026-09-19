#!/usr/bin/env bash
# netns_lab.sh -- stage N6: put the board behind a routed hop, with an ACL on the
# endpoint address range. No commercial simulator needed; this is the whole lab.
#
#   sudo ./net/netns_lab.sh up      eth0     # eth0 faces the board
#   sudo ./net/netns_lab.sh acl               # deny endpoints 4-7
#   sudo ./net/netns_lab.sh noacl
#   sudo ./net/netns_lab.sh test
#   sudo ./net/netns_lab.sh down    eth0
#
# Topology
#                                  ns r1 (router, forwarding on)
#   board 192.168.1.10-.18 --- eth0 192.168.1.1 | 10.0.0.1 veth --- ns h1 10.0.0.2
#
# From h1 the board is two hops away, so packets cross a real routing decision
# and a real filter. Set the board's default gateway to 192.168.1.1.
set -euo pipefail
ACTION=${1:?usage: $0 {up|down|acl|noacl|test} [iface]}
IFACE=${2:-eth0}

up() {
  ip netns add r1 2>/dev/null || true
  ip netns add h1 2>/dev/null || true
  ip link set "$IFACE" netns r1
  ip netns exec r1 ip addr add 192.168.1.1/24 dev "$IFACE"
  ip netns exec r1 ip link set "$IFACE" up
  ip netns exec r1 ip link set lo up
  ip link add v-r1 type veth peer name v-h1
  ip link set v-r1 netns r1
  ip link set v-h1 netns h1
  ip netns exec r1 ip addr add 10.0.0.1/24 dev v-r1
  ip netns exec r1 ip link set v-r1 up
  ip netns exec h1 ip addr add 10.0.0.2/24 dev v-h1
  ip netns exec h1 ip link set v-h1 up
  ip netns exec h1 ip link set lo up
  ip netns exec h1 ip route add default via 10.0.0.1
  ip netns exec r1 sysctl -qw net.ipv4.ip_forward=1
  ip netns exec r1 nft add table ip filter 2>/dev/null || true
  ip netns exec r1 nft 'add chain ip filter forward { type filter hook forward priority 0; policy accept; }' 2>/dev/null || true
  echo "up. Board gateway must be 192.168.1.1. From h1:"
  echo "  ip netns exec h1 ping -c1 192.168.1.13"
}

down() {
  ip netns exec r1 ip link set "$IFACE" netns 1 2>/dev/null || true
  ip netns del r1 2>/dev/null || true
  ip netns del h1 2>/dev/null || true
  echo "down. $IFACE returned to the root namespace."
}

acl() {
  ip netns exec r1 nft flush chain ip filter forward 2>/dev/null || true
  # Permit endpoints 0-3, deny 4-7. The NoC destination space is now filterable
  # by ordinary network policy, which is the point of the address plan.
  ip netns exec r1 nft add rule ip filter forward ip daddr 192.168.1.14-192.168.1.17 counter drop
  echo "ACL applied: .10-.13 permitted, .14-.17 denied."
  ip netns exec r1 nft list chain ip filter forward
}

noacl() {
  ip netns exec r1 nft flush chain ip filter forward
  echo "ACL cleared."
}

test_reach() {
  for n in 10 11 12 13 14 15 16 17 18; do
    printf "192.168.1.%s : " "$n"
    if ip netns exec h1 ping -c1 -W1 "192.168.1.$n" >/dev/null 2>&1; then
      echo "reachable"
    else
      echo "unreachable"
    fi
  done
}

case "$ACTION" in
  up) up ;; down) down ;; acl) acl ;; noacl) noacl ;; test) test_reach ;;
  *) echo "unknown action: $ACTION"; exit 1 ;;
esac
