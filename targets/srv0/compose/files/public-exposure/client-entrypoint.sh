#!/bin/bash
# DESC: Bring up the srv0 host side of the public-exposure tunnel and tear it
# down on stop. Runs inside the public-exposure-client-wg container (host
# network, NET_ADMIN). The raw INPUT/FORWARD accepts bypass firewalld, which
# drops packets arriving on an interface created at runtime (it gets no zone).
set -euo pipefail

IF=pubexp-client0
CONF=/etc/wireguard/pubexp-client0.conf

cleanup() {
    wg-quick down "$CONF" 2>/dev/null || true
    ip link del "$IF" 2>/dev/null || true
    while iptables -D INPUT -i "$IF" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$IF" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -o "$IF" -j ACCEPT 2>/dev/null; do :; done
    while iptables -t mangle -D FORWARD -o "$IF" -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
}
trap 'cleanup; exit 0' TERM INT

cleanup
iptables -I INPUT 1 -i "$IF" -j ACCEPT
iptables -I FORWARD 1 -i "$IF" -j ACCEPT
iptables -I FORWARD 1 -o "$IF" -j ACCEPT
# The srv0<->vps0 path is 1420 MTU; clamp forwarded SYNs (qBittorrent and other
# pod traffic) to the tunnel MTU so large segments aren't black-holed.
iptables -t mangle -A FORWARD -o "$IF" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu
wg-quick up "$CONF"
echo "public-exposure-client-wg: $IF up"

while true; do
    sleep 3600 &
    wait $!
done
