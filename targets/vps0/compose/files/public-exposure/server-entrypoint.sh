#!/bin/bash
# DESC: Bring up the public-exposure hub interface and its kernel port mappings
# and tear both down on stop. Runs inside the public-exposure-server-wg
# container (host network, NET_ADMIN). Host effects are lifecycle-bound: a
# SIGKILLed container's leftovers are cleaned first on the next start.
set -euo pipefail

IF=pubexp-server0
CONF=/etc/wireguard/pubexp-server0.conf
WATCH_PID=""

cleanup() {
    if [[ -n "$WATCH_PID" ]]; then
        kill "$WATCH_PID" 2>/dev/null || true
    fi
    bash /usr/local/bin/apply-forwards.sh down || true
    wg-quick down "$CONF" 2>/dev/null || true
    ip link del "$IF" 2>/dev/null || true
}
trap 'cleanup; exit 0' TERM INT

cleanup
wg-quick up "$CONF"
# Keep the tunnel MTU under whatever the current WAN path supports.
bash /usr/local/bin/mtu-watch.sh "$IF" &
WATCH_PID=$!
bash /usr/local/bin/apply-forwards.sh up
echo "public-exposure-server-wg: $IF up, port mappings applied"

while true; do
    sleep 3600 &
    wait $!
done
