#!/bin/bash
# DESC: Apply (up) or remove (down) the public-exposure kernel port mappings in
# the host netns. Reads forwards.conf:
#   "<tcp|udp> <public_port> <target_ip> <target_port> [masq]"
# "masq" SNATs the flow to the hub address so replies from targets that route
# via their own default (host services, initramfs) come back through the
# tunnel. Also clamps TCP MSS to the tunnel MTU (the srv0<->vps0 path is 1420,
# so the tunnel MTU is 1340). Invoked by the public-exposure-server-wg
# entrypoint, so every host rule is tied to that container's lifecycle; `up`
# removes stale copies first.
set -euo pipefail

[[ $# -eq 1 && ( $1 == up || $1 == down ) ]] || { echo "Usage: $0 <up|down>" >&2; exit 1; }
action="$1"

IF=pubexp-server0
FORWARDS=/etc/public-exposure/forwards.conf
HUB_ADDR=10.99.0.1
DOCKER_BRIDGE_CIDR=172.19.0.0/24
QBIT_ADDR=10.99.0.3/32
WG_PORT=51822

[ -r "$FORWARDS" ] || { echo "Error: $FORWARDS not readable" >&2; exit 1; }

down() {
    local proto port tip tport flag _
    while read -r proto port tip tport flag _; do
        while iptables -t nat -D PREROUTING -p "$proto" --dport "$port" \
            -j DNAT --to-destination "$tip:$tport" 2>/dev/null; do :; done
        if [ "$flag" = masq ]; then
            while iptables -t nat -D POSTROUTING -o "$IF" -d "$tip" -p "$proto" \
                --dport "$tport" -j MASQUERADE 2>/dev/null; do :; done
        fi
    done < <(grep -vE '^[[:space:]]*(#|$)' "$FORWARDS")
    while iptables -D INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null; do :; done
    while iptables -t mangle -D FORWARD -o "$IF" -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -s "$DOCKER_BRIDGE_CIDR" -o "$IF" \
        -j SNAT --to-source "$HUB_ADDR" 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -s "$QBIT_ADDR" ! -o "$IF" \
        -j MASQUERADE 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$IF" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -o "$IF" -j ACCEPT 2>/dev/null; do :; done
}

up() {
    local proto port tip tport flag _
    iptables -I INPUT 1 -p udp --dport "$WG_PORT" -j ACCEPT
    iptables -t nat -A POSTROUTING -s "$DOCKER_BRIDGE_CIDR" -o "$IF" \
        -j SNAT --to-source "$HUB_ADDR"
    iptables -t nat -A POSTROUTING -s "$QBIT_ADDR" ! -o "$IF" -j MASQUERADE
    iptables -t mangle -A FORWARD -o "$IF" -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu
    while read -r proto port tip tport flag _; do
        iptables -t nat -A PREROUTING -p "$proto" --dport "$port" \
            -j DNAT --to-destination "$tip:$tport"
        if [ "$flag" = masq ]; then
            iptables -t nat -A POSTROUTING -o "$IF" -d "$tip" -p "$proto" \
                --dport "$tport" -j MASQUERADE
        fi
    done < <(grep -vE '^[[:space:]]*(#|$)' "$FORWARDS")
    iptables -I FORWARD 1 -i "$IF" -j ACCEPT
    iptables -I FORWARD 1 -o "$IF" -j ACCEPT
}

case "$action" in
    up)
        down
        up
        echo "public-exposure: port mappings applied"
        ;;
    down)
        down
        echo "public-exposure: port mappings removed"
        ;;
esac
