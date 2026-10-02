#!/bin/bash
# DESC: Configure the host-network AmneziaWG interface for the VPN server pod.
# Runs as root in a hostNetwork pod (NET_ADMIN, spc_t). awg0, the NAT rule and
# the iptables FORWARD accepts live in the host netns and are torn down on
# SIGTERM; full-tunnel clients are masqueraded so LAN/WAN return traffic comes
# back through the tunnel. No host kernel module: awg-quick falls back to the
# userspace amneziawg-go implementation.
set -euo pipefail

WG_IF=awg0
WG_CONF=/wg/awg0.conf
WG_SUBNET=10.100.0.0/24

cleanup() {
    awg-quick down "$WG_CONF" 2>/dev/null || true
    ip link del "$WG_IF" 2>/dev/null || true
    rm -f "/var/run/amneziawg/$WG_IF.sock" 2>/dev/null || true
    while iptables -t nat -D POSTROUTING -s "$WG_SUBNET" ! -o "$WG_IF" -j MASQUERADE 2>/dev/null; do :; done
    while iptables -D FORWARD -s "$WG_SUBNET" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -d "$WG_SUBNET" -j ACCEPT 2>/dev/null; do :; done
}

# A previous pod may have been SIGKILLed; clear any leftover host-netns state.
cleanup

WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go awg-quick up "$WG_CONF"

iptables -t nat -A POSTROUTING -s "$WG_SUBNET" ! -o "$WG_IF" -j MASQUERADE

# Docker sets FORWARD to DROP and kube-router only accepts pod traffic, so
# non-pod forwarding (LAN/WAN) needs subnet-scoped accepts; pod-destined
# traffic is admitted by the allow-vpn-traefik NetworkPolicy.
iptables -I FORWARD 1 -s "$WG_SUBNET" -j ACCEPT
iptables -I FORWARD 1 -d "$WG_SUBNET" -j ACCEPT

trap 'cleanup; exit 0' TERM INT
while true; do
    sleep 3600 &
    wait $!
done
