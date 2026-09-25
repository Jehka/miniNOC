#!/usr/bin/env bash
# n6_lab.sh -- put the board behind a routed hop, with an ACL (stage N6)
#
# The board is a host on a directly attached segment. This builds a second
# subnet behind a router so that traffic to the endpoints crosses a real
# routing decision and a real filter, which is the point: the NoC destination
# space becomes filterable by ordinary network policy.
#
#   client ns 10.20.20.2  --veth--  router 10.20.20.1 / 10.10.10.1  --eth--  board 10.10.10.10-.18
#
# Replies come back without NAT: the board's default gateway is the router.
#
# Run on Linux, or on Windows under WSL2 with mirrored networking so that WSL
# can see the 10.10.10.1 interface:
#
#   # in C:\Users\<you>\.wslconfig
#   [wsl2]
#   networkingMode=mirrored
#   # then: wsl --shutdown, and reopen
#
# Check first that the board is reachable from WSL itself:  ping 10.10.10.10
#
#   sudo ./net/n6_lab.sh up
#   sudo ./net/n6_lab.sh test          # reachability from behind the router
#   sudo ./net/n6_lab.sh acl           # deny endpoints 4-7
#   sudo ./net/n6_lab.sh test          # .10-.13 answer, .14-.17 do not
#   sudo ./net/n6_lab.sh noacl
#   sudo ./net/n6_lab.sh down
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 {up|down|acl|noacl|test|run} [args]"
  exit 1
fi
ACTION=$1
BOARD_NET=10.10.10.0/24
CLIENT_NS=noc-client
FW=iptables            # nftables works too; iptables-nft is the common default

need_root() { [ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }; }

up() {
  need_root
  ip netns add $CLIENT_NS 2>/dev/null || true
  ip link add v-rtr type veth peer name v-cli 2>/dev/null || true
  ip link show v-cli >/dev/null 2>&1 && ip link set v-cli netns $CLIENT_NS
  ip addr add 10.20.20.1/24 dev v-rtr 2>/dev/null || true
  ip link set v-rtr up
  ip netns exec $CLIENT_NS ip addr add 10.20.20.2/24 dev v-cli
  ip netns exec $CLIENT_NS ip link set v-cli up
  ip netns exec $CLIENT_NS ip link set lo up
  ip netns exec $CLIENT_NS ip route add default via 10.20.20.1

  sysctl -qw net.ipv4.ip_forward=1
  # No NAT. The board's default gateway is 10.10.10.1, which is this router, so
  # it returns replies to 10.20.20.0/24 by itself: verified by deleting the
  # MASQUERADE rule and finding every endpoint still reachable. Traffic is
  # therefore routed in both directions, with the addresses left intact.
  echo "up. client namespace $CLIENT_NS at 10.20.20.2, router at 10.20.20.1"
  echo "traffic to the board now crosses one routing hop, no NAT."
}

down() {
  need_root
  $FW -D FORWARD -d 10.10.10.14/31 -j DROP 2>/dev/null || true
  $FW -D FORWARD -d 10.10.10.16/31 -j DROP 2>/dev/null || true
  ip netns del $CLIENT_NS 2>/dev/null || true
  ip link del v-rtr 2>/dev/null || true
  echo "down."
}

acl() {
  need_root
  # Permit endpoints 0-3 (.10-.13), deny endpoints 4-7 (.14-.17).
  # Two /31s cover .14-.17 exactly without touching memory at .18.
  $FW -C FORWARD -d 10.10.10.14/31 -j DROP 2>/dev/null || $FW -I FORWARD -d 10.10.10.14/31 -j DROP
  $FW -C FORWARD -d 10.10.10.16/31 -j DROP 2>/dev/null || $FW -I FORWARD -d 10.10.10.16/31 -j DROP
  echo "ACL applied: endpoints 0-3 permitted, endpoints 4-7 denied."
  $FW -S FORWARD | grep 10.10.10 || true
}

noacl() {
  need_root
  $FW -D FORWARD -d 10.10.10.14/31 -j DROP 2>/dev/null || true
  $FW -D FORWARD -d 10.10.10.16/31 -j DROP 2>/dev/null || true
  echo "ACL cleared."
}

test_reach() {
  need_root
  echo "from 10.20.20.2, two hops away:"
  for n in $(seq 10 18); do
    printf "  10.10.10.%-3s " "$n"
    if ip netns exec $CLIENT_NS ping -c1 -W1 "10.10.10.$n" >/dev/null 2>&1; then
      echo "reachable"
    else
      echo "BLOCKED / unreachable"
    fi
  done
}

# Run any command inside the client namespace, e.g.
#   sudo ./net/n6_lab.sh run python3 net/n5_errors.py
run_in_ns() {
  need_root
  shift || true
  ip netns exec $CLIENT_NS "$@"
}

case "$ACTION" in
  up) up ;; down) down ;; acl) acl ;; noacl) noacl ;; test) test_reach ;;
  run) run_in_ns "$@" ;;
  *) echo "unknown action: $ACTION"; exit 1 ;;
esac