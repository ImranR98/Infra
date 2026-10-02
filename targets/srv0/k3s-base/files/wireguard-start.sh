#!/bin/bash
# DESC: Configure the host-network WireGuard interface for the VPN server pod.
# Runs as root in a hostNetwork pod (NET_ADMIN, spc_t). wg0, the NAT rules and
# the iptables FORWARD accepts live in the host netns and are torn down on
# SIGTERM; full-tunnel clients are masqueraded so LAN/WAN return traffic comes
# back through the tunnel.
set -euo pipefail

WG_IF=wg0
WG_CONF=/wg/wg0.conf
WG_SUBNET=10.100.0.0/24
NAT_TABLE=wg_nat

cleanup() {
    wg-quick down "$WG_CONF" 2>/dev/null || true
    ip link del "$WG_IF" 2>/dev/null || true
    nft delete table ip "$NAT_TABLE" 2>/dev/null || true
    while iptables -D FORWARD -s "$WG_SUBNET" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -d "$WG_SUBNET" -j ACCEPT 2>/dev/null; do :; done
}

# A previous pod may have been SIGKILLed; clear any leftover host-netns state.
cleanup

wg-quick up "$WG_CONF"

nft add table ip "$NAT_TABLE"
nft "add chain ip $NAT_TABLE postrouting { type nat hook postrouting priority srcnat; policy accept; }"
nft add rule ip "$NAT_TABLE" postrouting ip saddr 10.100.0.0/24 oifname != "$WG_IF" masquerade

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
